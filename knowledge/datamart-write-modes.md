# データマートの書き込みモード（洗い替え → 増分更新 / SCD Type 2）: API 仕様

> 2026-09-09 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

「全件洗い替え」の BigQuery データマートを「増分更新」または「SCD Type 2」へ切り替える知識。
まず [`trocco-api.md`](./trocco-api.md) を読むこと。

> 参考記事（手動手順・判定基準の一次情報）:
> https://zenn.dev/primenumber/articles/c269ce4d26f3e6

## BigQuery データマートの書き込みモード

`datamart_bigquery_option` の主要フィールド:

| フィールド | enum / 型 | 説明 |
|---|---|---|
| `query_mode` | `insert` \| `query` | `insert`=データ転送モード（テーブル出力）/ `query`=自由記述 |
| `write_disposition` | `append` \| `truncate` \| `incremental` \| `scd_type_2` | 書き込みモード（`query_mode=insert` 時のみ有効） |
| `destination_dataset` / `destination_table` | string | 出力先 |
| `merge_keys` | string[] | レコードを一意識別するキー。`incremental` / `scd_type_2` で**必須** |
| `on_matched_action` | `upsert` \| `skip` | キー一致時の挙動。`incremental` で**必須**。upsert=DELETE→INSERT / skip=既存維持 |
| `incremental_column` | string | 増分基準カラム（例 `updated_at`）。`scd_type_2` で**必須** |
| `schema_evolution_mode` | `detect_only` \| `auto_add_column` | スキーマ自動追従。`incremental`/`scd_type_2` で有効（既定 detect_only） |
| `lookback_period_*` | 各種 | 処理対象期間の絞り込み（column/type/from/to/unit/timezone） |
| `partitioning` / `partitioning_time` / `partitioning_field` / `clustering_fields` | | パーティション/クラスタリング |

- **洗い替え** = `write_disposition: "truncate"`（WRITE_TRUNCATE）。これが切り替え候補。
- **増分更新** = `write_disposition: "incremental"` + `merge_keys` + `on_matched_action`。
- **SCD Type 2** = `write_disposition: "scd_type_2"` + `merge_keys` + `incremental_column`。
  管理列 `trocco_valid_from` / `trocco_valid_to` / `trocco_is_current` が自動付与される（読み取り専用・固定名）。

`query_mode`・`write_disposition` はいずれも PATCH（`/datamart_definitions/:id` への update）で変更可能。
ただし `data_warehouse_type`（BQ/Snowflake等）自体は作成後変更不可。

## 切り替え候補の検出

> [!CAUTION]
> **`datamart_bigquery_option` は一覧（index）に含まれない**（実測で確認。一覧側には 1 件も出ない）。
> `fetch_all datamart_definitions | jq 'select(.datamart_bigquery_option.write_disposition=="truncate")'`
> のような一覧だけの判定は、**必ず 0 件を返す**。候補なしと誤報告しないこと。
> `write_disposition` を見るには **1 件ずつ detail（`GET /datamart_definitions/:id`）が必要**。

そのため 2 段階で絞る。まず一覧で BigQuery 以外を落とし、残りだけ detail を取る。

```bash
# 1) 一覧から BigQuery のデータマートだけを抜く（ここは 1 件も detail を叩かない）
fetch_all datamart_definitions \
  | jq -r 'select(.data_warehouse_type == "bigquery") | .id' > "$TD/bq_ids.txt"
wc -l < "$TD/bq_ids.txt"   # ← これが必要な detail 取得回数

# 2) detail を取って write_disposition で分類する
while read -r id; do
  trocco-api.sh "/datamart_definitions/$id" 2>/dev/null \
    | jq -r '"\(.id)\t\(.datamart_bigquery_option.write_disposition // "-")\t\(.name)"'
done < "$TD/bq_ids.txt" > "$TD/dm_modes.tsv"

# 増分化の候補（awk を使う。grep -P は BSD grep で動かない）
awk -F'\t' '$2 == "truncate"' "$TD/dm_modes.tsv"
```

> [!IMPORTANT]
> **実行前に回数を見積もり、ユーザーに確認する。** detail はデータマート 1 件につき 1 回。
> BigQuery データマートが数百件あるアカウントなら、その件数ぶんの detail 取得が必要になる。
> トライアル（100 回/10 分）では完走できない。Advanced 以上（3,500 回/10 分）でも、
> 転送設定が数千件規模のアカウントでは、その全件走査と合わせると 1 ウィンドウに収まらない。
> 対象をチーム・リソースグループ・名前などで先に絞るか、分割実行する。

> Snowflake / Redshift のデータマートは別スキーマ（`datamart_snowflake_option` 等）。本ファイルは BigQuery を対象とする。

## 増分更新へ切り替える「前提条件」

以下がすべて満たされる場合のみ増分更新が適切（記事より）:

- 出力に**一意な merge キー**が存在する（そのキーで GROUP BY してカーディナリティ 1 になり、SELECT に含まれる）。
- **レコードがソースから消えない**（消える場合は洗い替え維持、または削除許容の判断が必要）。
- **キー単位で結果が決定的**（同じ入力なら常に同じ出力）。
- **行間依存がない**（ウィンドウ関数・累計など、処理ウィンドウ外の過去行を再計算する処理が無い）。

## 切り替え「不可」の 5 パターン（洗い替えを維持すべきケース）

1. **ソースからレコードが消える**（論理/物理削除）… 増分は消えた行を消せず、転送先に残留する。
2. **自然キー / 業務キーが存在しない** … merge キーを決められない。
3. **集計クエリで過去が遡って変わる** … 例: 注文キャンセルで前日集計が減る。ウィンドウ外の更新を取りこぼす。
4. **JOIN 結果がディメンション変更に依存** … 例: 顧客名変更。merge キーが注文 ID だけだと検知できない。
5. **行依存の計算**（ROW_NUMBER・累計等） … 新規行追加で過去行の計算結果も変わるが、ウィンドウ外は再計算されない。

## 増分更新への切り替え手順

1. `GET /datamart_definitions/:id` で現状（query, write_disposition, destination）を取得。
2. 上記「5 パターン」で適否を判定。該当すれば中止して理由を提示。
3. **merge キー**を選ぶ（クエリ出力で一意なカラム）。**処理ウィンドウ**（lookback）はジョブ間隔の 2〜3 倍を目安に late-arriving を吸収。
4. 変更案（before/after）を提示し承認を得る。
5. PATCH:

```json
{
  "datamart_bigquery_option": {
    "query_mode": "insert",
    "write_disposition": "incremental",
    "merge_keys": ["id"],
    "on_matched_action": "upsert",
    "lookback_period_column": "updated_at",
    "lookback_period_column_type": "TIMESTAMP",
    "lookback_period_unit": "days",
    "lookback_period_from": 3,
    "lookback_period_to": 0,
    "lookback_period_timezone": "Asia/Tokyo"
  }
}
```

6. 検証: 初回実行後、変更が無ければ再実行で行数が一致する。`SELECT COUNT(DISTINCT key)` がソースのカーディナリティと一致。

> [!NOTE]
> **`datamart_bigquery_option` は部分更新できる**（実測で確認）。変えたい項目だけを入れ子で送れば、
> 同じオブジェクト内の `query` / `destination_dataset` / `destination_table` / `bigquery_connection_id` は
> 保持される。クエリ全文を投げ返す必要はない。
>
> ```bash
> # write_disposition だけを変える。1 万文字を超えるクエリも保持された
> trocco-api.sh -X PATCH -H 'Content-Type: application/json' "/datamart_definitions/$id" \
>   -d '{"datamart_bigquery_option":{"write_disposition":"append"}}'
> ```

> [!NOTE]
> 増分データマートは**並列実行が自動で無効化**される。並列前提のワークフローは再スケジュールが必要。
> ロールバックは容易（`truncate` に戻して再実行すれば復元。スキーマ変更なし）。
> `truncate` に戻すと **`merge_keys` / `on_matched_action` / `schema_evolution_mode` は自動で解除される**
> （実測で確認）。手で null を送って消す必要はない。

> [!TIP]
> 必須項目が欠けている場合、400 の本文に不足項目名が入る。ユーザーへの報告にそのまま使える。
>
> ```json
> {"message":"Bad request. Please check your request payload",
>  "errors":[{"attribute":"incremental_column","message":"Incremental columnを入力してください。"}]}
> ```

## SCD Type 2 への切り替え手順

増分更新の全前提に加えて、**増分基準カラム（`incremental_column`）** と **履歴保持の業務要件**が必要。

```json
{
  "datamart_bigquery_option": {
    "query_mode": "insert",
    "write_disposition": "scd_type_2",
    "merge_keys": ["user_id"],
    "incremental_column": "updated_at",
    "schema_evolution_mode": "detect_only"
  }
}
```

- 管理列 `trocco_valid_from` / `trocco_valid_to`(NULL=現行) / `trocco_is_current`(BOOLEAN) が付与される。
- **下流クエリの書き換えが必須**: 最新行のみ欲しい箇所は `WHERE trocco_is_current = TRUE` を追加。
  - Point-in-time: `trocco_valid_from <= t AND (trocco_valid_to IS NULL OR trocco_valid_to > t)`
- 移行準備（推奨 = 記事の Option A）: 既存テーブルを DROP → 初回 SCD Type 2 ロードで管理列付きスキーマを自動生成
  （全行 `trocco_is_current=TRUE` で初期化）。
- **ロールバックは中〜高リスク**: テーブル DROP・再作成と、下流クエリの `trocco_is_current` 除去が必要。

## 進め方の戦略（記事の推奨）

- **1 つのデータマートから始める**。最も単純なケース（append-only or 明確な自然キーを持つトランザクション表）で成功させる。
- 全変換を一度にやらない。SCD Type 2 はクエリ書き換えコストが高いので、増分更新の成功後に検討する。
