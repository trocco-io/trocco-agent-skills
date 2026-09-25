# 差分転送への切り替え（転送設定）: API 仕様

> 2026-09-09 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

「全件洗い替え」の転送設定を「差分転送」に切り替えるための知識。
まず `trocco-api.md` を読むこと。

## 用語

- **全件洗い替え**: 毎回ソース全件を取得し、転送先を毎回作り直す（destination mode = `replace` / `truncate_insert`）。
- **差分転送**: 前回転送以降の増分のみを取得（source `incremental_loading_enabled`）し、
  転送先へ **merge（upsert）** する（destination mode = `merge`）。

差分転送化は **転送元（増分取得）と転送先（merge 書き込み）の両方**の設定変更が必要。

## 転送元: 増分取得（`incremental_loading_enabled`）

TROCCO API の input_option で増分取得を持つ主なコネクタ:

| コネクタ | input_option キー | 主なフィールド |
|---|---|---|
| MySQL | `mysql_input_option` | `incremental_loading_enabled`, `table`, `incremental_columns`, `last_record`, `query` |
| PostgreSQL | `postgresql_input_option` | 同上 |
| MongoDB | `mongodb_input_option` | `incremental_loading_enabled`, `incremental_columns`, `last_record`(object) |
| S3 | `s3_input_option` | `incremental_loading_enabled`（ファイル差分） |
| GCS | `gcs_input_option` | `incremental_loading_enabled`（ファイル差分） |
| SFTP | `sftp_input_option` | `incremental_loading_enabled`（ファイル差分） |
| Google Analytics 4 | `google_analytics4_input_option` | `incremental_loading_enabled` |
| HubSpot | `hubspot_input_option` | `incremental_loading_enabled` |

### DB コネクタの増分取得フィールド（MySQL / PostgreSQL）

| フィールド | 型 | 説明 |
|---|---|---|
| `incremental_loading_enabled` | boolean | `true`=差分転送 / `false`=クエリ転送 |
| `table` | string | **差分転送時は必須**。対象テーブル |
| `incremental_columns` | string | 増分判定カラム。カンマ区切り複数可。未指定なら PK を使用 |
| `last_record` | string | 最後に転送したレコードの基準値。これより新しいデータを取得。初回は null で全件 |
| `query` | string | `incremental_loading_enabled=false` のとき必須。差分転送時は指定不可 |

> - `incremental_loading_enabled=true` と `query` は**排他**。差分転送化では `query` を外し `table` を指定する。
> - MongoDB は `last_record` が object 型。

> [!IMPORTANT]
> **`incremental_loading_enabled` が `null`（キー自体が無い）＝そのコネクタが差分転送に非対応**（実測で確認）。
> 上表に無いコネクタ（salesforce / google_spreadsheets / bigquery / custom_connector など）は
> このフィールドを持たない。
>
> 検出条件を `== false` だけにすると、**洗い替えなのに非対応という定義が黙って候補から消える**
> （実測では、洗い替えの転送設定のうち 2 割前後がこれに該当したケースがある）。
> 次の **3 分類**にして報告すること:
>
> | 分類 | 条件 | 扱い |
> |---|---|---|
> | 差分転送化の候補 | `== false` かつ 転送先 mode が `replace`/`truncate_insert` | 適否判定へ進む |
> | すでに差分転送 | `== true` | 対象外（対応済み） |
> | **非対応コネクタ** | `== null`（キー無し） | **「差分転送非対応のため対象外: N 件」と明示報告** |

## 転送先: merge 書き込み

主要な転送先の `mode` enum（差分転送では `merge` を選ぶ）:

| 転送先 | mode enum | merge キー |
|---|---|---|
| BigQuery | `append`, `append_direct`, `replace`, `delete_in_advance`, `merge` | `bigquery_output_option_merge_keys[]` |
| PostgreSQL | `insert`, `insert_direct`, `truncate_insert`, `replace`, `merge` | `merge_keys[]` |
| MySQL | `insert`, `insert_direct`, `truncate_insert`, `replace`, `merge`, `merge_direct` | `merge_keys[]` |
| Snowflake | `insert`, `insert_direct`, `truncate_insert`, `replace`, `merge` | `snowflake_output_option_merge_keys[]` |
| Redshift | `insert`, `insert_direct`, `truncate_insert`, `replace`, `merge` | `merge_keys[]` |

- **洗い替え判定**: 現状 mode が `replace` または `truncate_insert` のものが「全件洗い替え」候補。
- **差分化**: mode を `merge` に変更し、merge キーを指定する。

## 切り替えの適否（重要）

データマートの増分化と同じ制約が転送にも当てはまる。以下に該当する場合は洗い替えのままにする:

1. **ソースからレコードが消える**（論理/物理削除）… merge は「消えた行」を反映できない。
2. **一意キーが無い** … merge キーを決められない。
3. **集計・JOIN 結果が遡って変わる** … 増分ウィンドウ外の過去行が更新されず取り残される。

詳細な判定基準は `datamart-write-modes.md` の「切り替え不可の 5 パターン」を流用する。

## 切り替え手順（GET → 構築 → 確認 → PATCH）

> [!IMPORTANT]
> `input_option` / `output_option` は**部分更新できる**（実測で確認）。**変える項目だけを入れ子で送る。**
> オブジェクト全体を組み立て直さない。組み立て直すほど、送信内容が増えて取りこぼしの余地も増える。
>
> ```bash
> # 転送先を merge に切り替える。出力先・接続・ロケーションは送らなくても保持される
> trocco-api.sh -X PATCH -H 'Content-Type: application/json' "/job_definitions/$id" -d '{
>   "output_option": { "bigquery_output_option": {
>     "mode": "merge", "bigquery_output_option_merge_keys": ["id"] } } }'
> ```
>
> なお GET レスポンスと PATCH 入力のスキーマは常に一致するとは限らない。部分更新で足りる以上、
> **GET 結果をそのまま投げ返す必要はない**。実行前に必ず差分を提示すること。

1. `GET /job_definitions/:id` で現状（input/output option, mode）を取得。
2. 適否チェック（上記 3 パターン）。merge キー候補と増分カラム候補をユーザーに確認。
3. 変更案（before/after）を提示:
   - 転送元: `incremental_loading_enabled: true`, `table`, `incremental_columns` を設定、`query` を外す。
   - 転送先: `mode: "merge"`, merge キー配列を設定。
4. 承認後、まず 1 件だけ PATCH → テスト実行（`POST /job_definitions/:id/jobs` 相当は無いため UI or 手動実行）で
   件数・整合性を検証 → 問題なければ横展開。

```jsonc
// MySQL(全件クエリ) → 差分転送 の PATCH 例（BigQuery 転送先を merge に）
{
  "input_option": {
    "mysql_input_option": {
      "database": "mydb", "mysql_connection_id": 12,
      "incremental_loading_enabled": true,
      "table": "orders",
      "incremental_columns": "updated_at",
      "last_record": null
      // query は指定しない
    }
  },
  "output_option": {
    "bigquery_output_option": {
      "mode": "merge",
      "bigquery_output_option_merge_keys": ["id"]
    }
  }
}
```

> 初回の差分転送は `last_record: null` から始まり全件を取り込む。以降は増分のみ。
