# 通知（Notifications）: API 仕様

> 2026-09-09 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

転送設定・データマート・ワークフローに設定できる通知の構造。
まず `trocco-api.md` を読むこと（特に「配列は洗い替え」の項）。

## 2 段階のモデル: 通知先(destination) と 通知(notification)

TROCCO の通知は 2 レイヤーに分かれる。

1. **通知先（Notification Destination）** … アカウント共通の宛先。Slack チャンネル / Email / HTTP。
2. **通知（Notification）** … 各定義に紐づく「どの通知先に・どういう条件で送るか」の設定。
   通知先を `id` で参照する。

### 通知先エンドポイント `/notification_destinations/:type`

`:type` は `email` または `slack_channel`。

```bash
# Email 通知先の一覧
trocco-api.sh "/notification_destinations/email"
# Slack 通知先の一覧
trocco-api.sh "/notification_destinations/slack_channel"
```

通知先スキーマ: `{ id, type(email|slack_channel), email?, channel? }`

> [!IMPORTANT]
> **通知先は API では作成できない。画面で作成済みのものを参照するだけ**（実測で確認）。
> `POST /notification_destinations/email` は `400 Bad request` を返す。
> `/notification_destinations` は公式 API ドキュメントのエンドポイント一覧にも記載が無く、
> GET は動作するが、仕様が予告なく変わる可能性を考慮しておくこと。
>
> 通知を付与する手順は次の順に進める。
>
> 1. `GET /notification_destinations/email` と `.../slack_channel` で既存の通知先を一覧する。
> 2. どの通知先を使うかをユーザーに選んでもらう。
> 3. その `id` を各定義の `notifications` に設定する。
>
> 使いたい通知先が存在しない場合は、**画面で作成してもらってから再実行する**よう案内する。

## 定義ごとの通知スキーマ

通知先 `id` を参照して、各定義の `notifications` 配列に設定する。
**`notifications` は配列なので PATCH では洗い替え**。追加時は GET→append→全量 PATCH。

### 転送設定（job_definition）の通知

`notifications[]`（最大 20 件）。必須は `destination_type` / `notification_type` / `message` の 3 つ:

| フィールド | 型 / enum | 必須条件 |
|---|---|---|
| `destination_type` | `slack` \| `email` \| `http` | 常に必須 |
| `slack_channel_id` | integer | `destination_type=slack` のとき |
| `email_id` | integer | `destination_type=email` のとき |
| `http_notification_destination_id` | integer | `destination_type=http` のとき |
| `notification_type` | `job` \| `record` \| `exec_time` | 常に必須 |
| `message` | string | **常に必須** |
| `notify_when` | `finished` \| `failed` | `notification_type=job` のとき |
| `record_count` | integer | `notification_type=record` のとき |
| `record_operator` | `above` \| `below` | `notification_type=record` のとき |
| `record_type` | `transfer` \| `skipped` | `notification_type=record` のとき |
| `minutes` | integer（分） | `notification_type=exec_time` のとき |

- `job` … ジョブの完了 / 失敗通知
- `record` … 転送レコード件数のしきい値通知
- `exec_time` … 実行時間経過アラート。閾値は `minutes` で指定する

> [!CAUTION]
> `message` は**省略できない**。また実行時間アラートの値は `time` ではなく **`exec_time`** である。
> `destination_type=http` の `job` 通知では、`message` に JSON 形式の文字列を渡す必要がある。

例（失敗時に Slack 通知）:

```json
{
  "notifications": [
    { "destination_type": "slack", "slack_channel_id": 12,
      "notification_type": "job", "notify_when": "failed",
      "message": "転送に失敗しました" }
  ]
}
```

### データマート定義（datamart_definition）の通知

`notifications[]`（最大 20 件）。転送設定とほぼ同じだが、`notification_type` は `job` \| `record` の 2 種で、
`message` は必須ではない（必須は `destination_type` / `notification_type`）:

| フィールド | 型 / enum | 必須条件 |
|---|---|---|
| `destination_type` | `slack` \| `email` \| `http` | 常に必須 |
| `slack_channel_id` / `email_id` / `http_notification_destination_id` | integer | destination_type に応じて |
| `notification_type` | `job` \| `record` | 常に必須 |
| `notify_when` | `finished` \| `failed` | `notification_type=job` |
| `record_count` / `record_operator` | integer / `above`\|`below` | `notification_type=record` |
| `message` | string | 任意 |

### ワークフロー定義（pipeline_definition）の通知: スキーマが異なる

`notifications[]`。**転送/データマートと構造が違う**ので注意:

| フィールド | 型 / enum | 必須条件 |
|---|---|---|
| `type` | `job_execution` \| `job_time_alert` | 常に必須 |
| `destination_type` | `slack` \| `email` \| `http` | 常に必須 |
| `notify_when` | `finished` \| `failed` | `type=job_execution` |
| `time` | integer（分） | `type=job_time_alert` |
| `slack_config` | `{ notification_id, message }` | `destination_type=slack` |
| `email_config` | `{ notification_id, message }` | `destination_type=email` |
| `http_config` | object | `destination_type=http` |

- 通知先の参照は `slack_channel_id`/`email_id` ではなく **`slack_config.notification_id` / `email_config.notification_id`**。
- ワークフローでは実行時間アラートの項目名が **`time`**（転送設定の `exec_time` / `minutes` とは異なる）。

例（失敗時 Slack + 60 分超過アラート）:

```json
{
  "notifications": [
    { "type": "job_execution", "destination_type": "slack",
      "notify_when": "failed",
      "slack_config": { "notification_id": 12, "message": "WF 失敗" } },
    { "type": "job_time_alert", "destination_type": "email",
      "time": 60, "email_config": { "notification_id": 5, "message": "60分超過" } }
  ]
}
```

## 「通知が無い定義」の検出

各定義を GET し、`notifications` が空配列 / null かどうかで判定する。

```bash
# 通知が付いていない転送設定の id と名前を列挙
fetch_all job_definitions \
  | jq -r 'select((.notifications // []) | length == 0) | "\(.id)\t\(.name)"'
```

> [!NOTE]
> `notifications` は 3 種別とも **一覧（index）に含まれる**（実測で確認）。検出だけなら per-id GET は不要。
> ただし通知が無い定義では**キーごと省略される**ため、必ず `(.notifications // [])` の形で判定すること。
