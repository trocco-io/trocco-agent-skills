# ワークフロー（Pipeline Definitions）: API 仕様

> 2026-09-09 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

個別スケジュールされた転送/データマートをワークフローへ集約するための知識。
まず [`trocco-api.md`](./trocco-api.md) を読むこと。

## ワークフロー定義の構造

`/pipeline_definitions`（index/show/create/destroy + member `update`(PATCH)）。

主要フィールド:

| フィールド | 説明 |
|---|---|
| `name` / `description` | 名称・メモ |
| `resource_group_id` | リソースグループ |
| `max_task_parallelism` | タスク最大並列度 |
| `is_stopped_on_errors` | エラー時に停止するか |
| `labels` | ラベル配列 |
| `tasks` | タスク（ステップ）配列 |
| `task_dependencies` | タスク間依存配列 |
| `schedules` | スケジュール配列（洗い替え） |
| `notifications` | 通知配列（洗い替え・スキーマは [`notifications.md`](./notifications.md) 参照） |

## タスク（tasks[]）

各タスク: `{ key, type, <type>_config }`

- `key`: ワークフロー内で一意な識別子（例 `t1`, `transfer_orders`）。依存関係はこの key で結ぶ。
- `type`: タスク種別。主なもの:

```
trocco_transfer            既存の転送設定を参照
trocco_transfer_bulk       バルク転送
trocco_bigquery_datamart   BigQuery データマート定義を参照
trocco_snowflake_datamart  Snowflake データマート定義を参照
trocco_redshift_datamart   / trocco_databricks_datamart
trocco_dbt                 dbt 定義を参照
trocco_pipeline            ネストしたワークフローを参照
bigquery_data_check        データチェック（BigQuery / snowflake / redshift / databricks）
http_request / slack_notify / tableau_extract / if_else
```

- `<type>_config`: 種別ごとの設定。既存定義を参照するタスクは **`definition_id`（参照先定義の id）** と `name` を持つ。

```json
{
  "key": "transfer_orders",
  "type": "trocco_transfer",
  "trocco_transfer_config": { "definition_id": 100, "name": "注文テーブル転送" }
}
```

```json
{
  "key": "dm_sales",
  "type": "trocco_bigquery_datamart",
  "trocco_bigquery_datamart_config": { "definition_id": 200, "name": "売上データマート" }
}
```

## タスク依存（task_dependencies[]）

`{ source, destination }`: 「`destination` は `source` の完了を待つ」（source → destination）。
**書き込み時はタスクの `key`（文字列）で指定する。**

```json
{ "task_dependencies": [ { "source": "transfer_orders", "destination": "dm_sales" } ] }
```

- 循環依存は拒否される（400 `{"error":"タスクの依存関係が不正です"}`。実測で確認）。
- `type` は参照先定義のモデル種別と一致必須（転送定義を `trocco_bigquery_datamart` で参照する等は不可）。
  食い違うと **404 `Not found`** が返る。ワークフロー自体は存在するので、404 を「ワークフローが無い」と
  誤読しないこと（実測で確認）。

## 最大の落とし穴: GET の結果を PATCH に投げ返せない

> [!CAUTION]
> **ワークフローは GET → 編集 → PATCH の往復ができない**（実測で確認）。理由は 2 つ。
>
> 1. **GET（show）のレスポンスに `tasks[].key` が含まれない**。代わりに `task_identifier`（整数）が返る。
> 2. **`task_dependencies` が `{"source":1,"destination":2}` と整数で返る**。PATCH は文字列 `key` しか受け付けない。
>
> GET の出力をそのまま PATCH へ渡すと、API は自分の出力をこう拒否する。
>
> ```
> HTTP 400 {"message":"Tasks keyが必要です, Tasks keyが必要です, Task dependenciesは無効な 配列 です","errors":[]}
> ```
>
> 公式 OpenAPI では入出力とも `key`（文字列）と定義されており、**実装がスペックと食い違っている**。
> スペックではなく実際のレスポンスを見て組むこと。

### 対処 1（推奨）: tasks を変えないなら送らない

スケジュール・通知・名前・説明だけを変えたい場合は、**`tasks` と `task_dependencies` を送らない**。
トップレベルは差分更新なので、送らなければタスク構成は保持される（実測で確認）。
個別スケジュールをワークフローへ移設する作業は、この方法で足りる。

```bash
# tasks には触れず、スケジュールだけ設定する（name は PATCH の必須項目）
trocco-api.sh -X PATCH -H 'Content-Type: application/json' "/pipeline_definitions/$id" \
  -d '{ "name": "<現在の名前>", "schedules": [ { "frequency": "daily", "hour": 5, "minute": 0, "time_zone": "Asia/Tokyo" } ] }'
```

### 対処 2: タスク構成を変えるなら key を振り直す

`key` は GET から復元できないため、**配列の並び順で採番し直し、`task_identifier` から対応付ける**。

```bash
trocco-api.sh "/pipeline_definitions/$id" > "$TD/wf.json"
jq '
  (.tasks | to_entries | map({(.value.task_identifier|tostring): "t\(.key+1)"}) | add) as $map
  | { name,
      tasks: [.tasks[] | . + {key: $map[.task_identifier|tostring]} | del(.task_identifier)],
      task_dependencies: [.task_dependencies[]
        | {source: $map[.source|tostring], destination: $map[.destination|tostring]}] }
' "$TD/wf.json" > "$TD/payload.json"
# payload.json に必要な変更を加えてから PATCH する
```

- `task_identifier` は **`tasks` を含む PATCH のたびに採番し直される**（実測では 1,2 → 3,4 に変化）。
  値を保存して後から参照しない。
- `tasks` は配列なので洗い替え。一部だけ変えたい場合も全量を送る。

> [!NOTE]
> `<type>_config.name` に何を書いても、**サーバーが参照先定義の実際の名前で上書きする**（実測で確認）。
> 表示名を API から変えることはできないので、値を合わせようとしなくてよい。

## スケジュール（schedules[]）

転送/データマートと共通の schedule スキーマ:

| フィールド | 型 / enum | 必須 |
|---|---|---|
| `frequency` | `hourly` \| `daily` \| `weekly` \| `monthly` | ✅ |
| `time_zone` | IANA（例 `Asia/Tokyo`, `Etc/UTC`） | ✅ |
| `minute` | 0-59 | 適宜 |
| `hour` | 0-23 | daily/weekly/monthly |
| `day` | 1-31 | monthly |
| `day_of_week` | 0-6（0=日） | weekly |

- **schedules は配列 → PATCH で洗い替え**。転送/データマートの schedules と同一構造なので、
  個別定義の schedule をワークフローへ「移設」できる。

## 既存定義を束ねるワークフローの新規作成（フル例）

```json
POST /api/pipeline_definitions
{
  "name": "日次: 注文 → 売上データマート",
  "resource_group_id": 45,
  "max_task_parallelism": 1,
  "is_stopped_on_errors": true,
  "schedules": [ { "frequency": "daily", "time_zone": "Asia/Tokyo", "hour": 5, "minute": 0 } ],
  "notifications": [
    { "type": "job_execution", "destination_type": "slack", "notify_when": "failed",
      "slack_config": { "notification_id": 12, "message": "日次WF失敗" } }
  ],
  "tasks": [
    { "key": "transfer_orders", "type": "trocco_transfer",
      "trocco_transfer_config": { "definition_id": 100, "name": "注文テーブル転送" } },
    { "key": "dm_sales", "type": "trocco_bigquery_datamart",
      "trocco_bigquery_datamart_config": { "definition_id": 200, "name": "売上データマート" } }
  ],
  "task_dependencies": [ { "source": "transfer_orders", "destination": "dm_sales" } ]
}
```

## 個別スケジュール → ワークフロー集約の考え方

1. 個別に schedule を持つ転送/データマートを列挙。`schedules` は **index に含まれる**（実測で確認）ので
   一覧だけで判定でき、per-id GET は不要。空だとキーごと省略されるため `(.schedules // [])` で判定する。
2. **同一 time_zone・近い時刻・依存関係がありそうなもの**をグルーピングして「束ねる候補」を提示。
3. ワークフロー作成後、**元の個別 schedule を外す**（`schedules: []` を PATCH）ことで二重実行を防ぐ。
   → この「元 schedule 削除」は破壊的なので必ず確認・段階適用する。

> [!CAUTION]
> **スケジュールの ON/OFF は公開 API では判別できない**（実地検証で確認）。`schedules[]` に
> 有効/無効フラグは無く、UI で OFF にされたスケジュールも ON のものと同じ形で返る。
> つまり「schedules がある = 実際に定期実行されている」とは限らない。意図的に停止中の定義を
> ワークフローへ集約すると、**実質的に再有効化してしまう**恐れがある。
> 集約候補は「現在 ON かどうか」を必ずユーザーに確認してから移設すること。
>
> また一部コネクタ（例 `custom_connector` ソース）は detail 取得が HTTP 400 になる。
> その定義はスケジュール有無を API から確認できないため、対象外として明示的に報告する。
