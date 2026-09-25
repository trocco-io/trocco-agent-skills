---
name: optimize-datamart-incremental
description: 全件洗い替え（truncate）の TROCCO BigQuery データマートを、増分更新（incremental）または SCD Type 2 へ切り替える。適否を5パターンで判定し安全に移行する。「洗い替えデータマートを増分更新にして」「SCD Type 2 にして」と依頼されたときに使う。
---

# 洗い替え BQ データマート → 増分更新 / SCD Type 2 への切り替え

`write_disposition: "truncate"`（全件洗い替え）の BigQuery データマートを、
増分更新（`incremental`）または SCD Type 2（`scd_type_2`）へ移行する。

## 大原則: API はラッパー `trocco-api.sh` 経由で呼ぶ

`curl` で直接叩かない。ベース URL と `Authorization` ヘッダーはラッパーが所有するので、
**パス以降と curl 引数だけ**を渡す（API キーの値を読む必要はない）。

ラッパーの置き場所は導入方法によって変わる。まず次でパスを確定する。

```bash
# ls はエイリアス（-F 等）で表示が変わることがあるため使わない
for p in {.claude,.agents}/skills/optimize-datamart-incremental/scripts/trocco-api.sh bin/trocco-api.sh; do
  [ -f "$p" ] && echo "$p" && break
done
```

以降この SKILL.md と `references/` に出てくる `trocco-api.sh` は、確定したパスに読み替えて実行する。
コマンドごとにシェルは切り替わるため、変数には入れず毎回フルパスで書く。

```bash
bash .claude/skills/optimize-datamart-incremental/scripts/trocco-api.sh "/job_definitions?limit=200"   # パスは確定した値に置き換える
```

## 前提知識（必ず先に読む）
- [`knowledge/trocco-api.md`](./references/trocco-api.md)
- [`knowledge/datamart-write-modes.md`](./references/datamart-write-modes.md): フィールド仕様・適否 5 パターン・手順
- 一次情報（手動手順）: https://zenn.dev/primenumber/articles/c269ce4d26f3e6

## 手順

### 1. 候補の洗い出し（読み取りのみ）
`datamart_bigquery_option.write_disposition == "truncate"` のデータマートを列挙。

> [!CAUTION]
> **`datamart_bigquery_option` は一覧（index）に含まれない**（実測で確認）。一覧だけで
> `write_disposition` を判定すると**必ず 0 件になる**ので、候補なしと誤報告しないこと。
> 一覧で `data_warehouse_type == "bigquery"` に絞ってから、**1 件ずつ detail を取る**。
> 手順は [`knowledge/datamart-write-modes.md`](./references/datamart-write-modes.md)「切り替え候補の検出」。

> [!NOTE]
> **レートリミットに注意**（10 分あたり トライアル 100 回 / Advanced 以上 3,500 回）。
> この skill は対象 1 件につき detail を 1 回取得するため、対象が多いと上限に近づく。
> **実行前に必要回数を見積もり**（一覧 ≒ 全件÷200 回 ＋ detail ≒ 対象件数）、
> 上限に対して大きい場合は対象を絞るかユーザーに確認する。
> ラッパーは 429 を自動リトライする。残量確認:
> `trocco-api.sh '/teams?limit=1' -o /dev/null -D - 2>/dev/null | grep -i x-rate-limit`

### 1.5 対象外を分離する（分母に混ぜない）
- **DWH が BigQuery 以外**（Snowflake / Redshift / Databricks など）は本 skill の対象外。
  `data_warehouse_type` で先に分離する（`write_disposition` の考え方は共通だが、本 skill の手順は BQ 前提）。
- **`query_mode=query`（自由記述モード）** は `write_disposition` を持たないため増分化できない。対象外。
- detail GET が **HTTP 400** になるものはスキップ。

「対象 N 件」とだけ出さず、次のように分けて提示する:

```
BigQuery データマート: N 件
  増分化候補（truncate）: A 件
  対象外: append B / 自由記述モード C / SCD Type 2 D
BigQuery 以外: E 件（対象外）
未処理（HTTP 400 等）: F 件
```

### 2. 適否判定（切り替え不可の 5 パターン）
1. ソースからレコードが消える  2. 一意キーが無い  3. 集計が遡って変わる
4. JOIN 結果がディメンション変更に依存  5. 行依存の計算（ROW_NUMBER・累計）
→ 該当すれば洗い替え維持を推奨し、理由を提示する。

### 3. 増分更新 or SCD Type 2 の選択
- 最新値のみで良い → **増分更新**（`incremental` + `merge_keys` + `on_matched_action`）。ロールバック容易。
- 変更履歴を保持したい → **SCD Type 2**（`scd_type_2` + `merge_keys` + `incremental_column`）。
  管理列（`trocco_valid_from/valid_to/is_current`）が付き、**下流クエリの書き換えが必須**。ロールバック中〜高リスク。
- まず増分更新から始め、最も単純な 1 つで成功させることを推奨。

### 4. 変更案の提示と適用（ユーザー承認が必須）
- merge キー（出力で一意なカラム）、増分基準カラム、lookback ウィンドウ（ジョブ間隔の 2〜3 倍）を確認。
- before/after を提示。PATCH `/datamart_definitions/:id`（ペイロード例は knowledge 参照）。

### 5. 検証
- 初回実行後、変更が無ければ再実行で行数一致。`COUNT(DISTINCT key)` がソースのカーディナリティと一致。
- 増分データマートは並列実行が自動無効化される点をワークフロー側に反映。
- SCD Type 2 の場合は下流クエリに `WHERE trocco_is_current = TRUE` 等の書き換えを案内。

## やってはいけないこと
- 適否 5 パターンの判定を飛ばさない。
- SCD Type 2 で下流クエリ書き換えの案内を省略しない（重複行が返る）。
