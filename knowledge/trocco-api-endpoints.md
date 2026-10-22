# TROCCO API: リソース種別とエンドポイント

> 2026-10-20 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

TROCCO API が扱うリソースとジョブのエンドポイントの一覧。
各 skill は、使うエンドポイントを話題別のドキュメント（notifications.md や job-logs.md など）で確認する。
この一覧は skill を追加・設計するときに、どのリソースが API で操作できるかを見渡すためのもの。

## リソース種別と主要エンドポイント

| 種別 | 日本語 | ベースパス | index/show/create/update/destroy |
|---|---|---|---|
| 転送設定 | Transfer | `/job_definitions` | ✅ / ✅ / ✅ / ✅(PATCH) / ✅ |
| データマート定義 | Datamart | `/datamart_definitions` | ✅ / ✅ / ✅ / ✅(PATCH member `update`) / ✅ |
| ワークフロー定義 | Pipeline | `/pipeline_definitions` | ✅ / ✅ / ✅ / ✅(PATCH) / ✅ |
| dbtジョブ設定 | dbt | `/dbt_job_definitions` | ✅ / ✅ / ✅ / ✅ / ✅ |
| ユーザー | User | `/users` | ✅ / ✅ / ✅ / ✅ / ✅ |
| リソースグループ | Resource Group | `/resource_groups` | ✅ / ✅ / ✅ / ✅ / ✅ |
| 通知先 | Notification Destination | `/notification_destinations/:type` | ✅ / ✅ / ✅ / ✅ / ✅ |
| チーム | Team | `/teams` | ✅ / ✅ / ✅ / ✅ / ✅ |
| ラベル | Label | `/labels` | ✅ / ✅ / ✅ / ✅ / ✅ |
| 接続情報 | Connection | `/connections/:connection_type` | ✅ / ✅ / ✅ / ✅ / ✅ |
| dbt Git リポジトリ | dbt Git Repository | `/dbt_git_repositories` | ✅ / ✅ / ✅ / ✅ / ✅ |
| カスタムコネクタ | Custom Connector | `/custom_connectors`（一覧）, `/custom_connector_inputs`, `/custom_connector_outputs` | ✅ / ✅ / ✅ / ✅ / ✅ |
| 環境グループ | Environment Group | `/environment_groups` | ✅ / ✅ / ✅ / ✅ / ✅ |
| 環境 | Environment | `/environments` | ✅ / ✅ / ✅ / ✅ / ✅ |

## ジョブ（実行・実行結果・実行ログ）

| ジョブ種別 | 実行 | 実行結果 | 一覧 | 実行ログ |
|---|---|---|---|---|
| 転送ジョブ | `POST /jobs` | `GET /jobs/:job_id` | `GET /job_definitions/:id/jobs` | `GET /jobs/:job_id/logs` |
| データマートジョブ | `POST /datamart_jobs` | `GET /datamart_jobs/:id` | なし | `GET /datamart_jobs/:id/logs` |
| dbt ジョブ | なし | `GET /dbt_jobs/:id` | なし | `GET /dbt_jobs/:id/logs` |
| ワークフロージョブ | `POST /pipeline_jobs` | `GET /pipeline_jobs/:id` | なし | なし |

> [!IMPORTANT]
> **転送・データマート・dbt ジョブの実行ログ（エラーログを含む）は API で取得できる**。
> 実行結果（`/jobs/:id` など）が返すのはステータス・件数（`transfer_record` など）・日時だけで、エラー理由は含まない。
> エラー理由は実行ログから読む。
> 「API ではジョブのエラー内容を確認できない」と判断しないこと。仕様と読み方は [`job-logs.md`](./job-logs.md) を参照。
> ワークフロージョブだけは実行ログ API も、タスク単位の結果を返す API も無い。ワークフローの失敗を調べるときは、
> 実際に失敗したタスクのジョブ ID をユーザーに貰う。そのタスクが転送・データマート・dbt なら、そのジョブのログを取得できる。
> ジョブの一覧は [`job-search.md`](./job-search.md) を参照。
