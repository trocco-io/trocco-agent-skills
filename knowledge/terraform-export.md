# TROCCO リソースの Terraform エクスポート: 仕組みと仕様

> 2026-09-09 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

既存の TROCCO リソースを読み取り、TROCCO Terraform Provider 準拠の `.tf` を生成するための知識。
まず [`trocco-api.md`](./trocco-api.md) を読むこと。

## 一次情報とバージョン注記

- **Provider ドキュメント（ユーザー向け一次情報）**: https://registry.terraform.io/providers/trocco-io/trocco/latest/docs
- Provider source: `trocco-io/trocco`（registry: `registry.terraform.io/trocco-io/trocco`）
- **skill 作成時点の最新は v0.33.0**（`~> 0.33` の制約では実測で v0.36.0 が解決された）。リソースの属性は provider 更新で追加/変更されうるため、
  齟齬が出た場合は**必ず上記の公式 docs を正とする**。
- Terraform は **1.5 以上**が必要（`import {}` ブロックと `-generate-config-out` を使うため）。
- Provider の TROCCO API 機能は**有料プランのみ**で利用可能。

## 基本方針: 「API で列挙 → import → generate-config-out」

provider には**リソースを名前や条件で検索する data source が無い**。そのため
「どの id をエクスポートするか」を Terraform 単体では解決できない。
この**列挙（discovery）を TROCCO API の GET が担い**、Terraform 純正の設定生成に橋渡しする。

1. TROCCO API の GET で対象リソースを列挙し、`id`（と `name`）を得る。
2. `import { to = <tf_type>.<addr>, id = "<id>" }` ブロックを生成する。
3. `terraform plan -generate-config-out=<file>` を実行 → provider が Read して HCL を自動生成する。

**利点**: 生成される HCL は常に provider schema に一致し、フィールド対応表を自前保守しなくてよい。

## リソース種別 → provider リソース → API 列挙元

| 種別 | Terraform リソース | API 列挙元（GET） | 備考 |
|---|---|---|---|
| 転送設定 | `trocco_job_definition` | `/api/job_definitions` | |
| データマート(BigQuery) | `trocco_bigquery_datamart_definition` | `/api/datamart_definitions`（`data_warehouse_type=bigquery`） | **BQ のみ対応** |
| ワークフロー | `trocco_pipeline_definition` | `/api/pipeline_definitions` | |
| dbt ジョブ | `trocco_dbt_job_definition` | `/api/dbt_job_definitions` | |
| dbt Git リポジトリ | `trocco_dbt_git_repository` | `/api/dbt_git_repositories` | |
| リソースグループ | `trocco_resource_group` | `/api/resource_groups` | |
| チーム | `trocco_team` | `/api/teams` | |

> **データマートは BigQuery のみ**。provider に Snowflake/Redshift データマートのリソースは無い
> （v0.33.0 時点）。それらは対象外として明示し、手動対応を案内する。公式 docs で最新の対応状況を確認すること。
> import ID はいずれも**数値 id**（例 `import { to = trocco_team.x, id = "28" }`）。

## Provider 設定（環境変数）

Provider は API キーを環境変数から読む:

- `TROCCO_API_KEY` … API キー

> [!IMPORTANT]
> **ラッパー `trocco-api.sh` の資格情報は Terraform に引き継がれない**。ラッパーはトークンファイルや
> 1Password からキーを解決し、**あえてエージェントの環境変数に置かない**設計になっている。
> 一方 provider が読むのは環境変数 `TROCCO_API_KEY`（または HCL の `api_key`）だけなので、
> 推奨方式（トークンファイル）の利用者がそのまま `terraform plan` を叩くと必ず次で失敗する。
>
> ```
> Error: Missing api key
> ```
>
> terraform を実行するコマンドに限ってキーを渡す。値を `echo` せず、環境変数にも残さない。
>
> ```bash
> # トークンファイル方式
> TROCCO_API_KEY="$(tr -d '\r\n' < ~/.config/trocco/token)" terraform plan -generate-config-out=generated.tf
>
> # 1Password 方式
> op run --env-file=~/.config/trocco/.env -- terraform plan -generate-config-out=generated.tf
> ```
>
> 環境変数方式（`$TROCCO_API_KEY` を設定済み）の場合は、そのまま `terraform` を実行すればよい。

```hcl
terraform {
  required_providers {
    trocco = {
      source  = "trocco-io/trocco"
      version = "~> 0.33"
    }
  }
}

provider "trocco" {
  # api_key は環境変数 TROCCO_API_KEY で解決
}
```

> API 列挙（`https://trocco.io/api`）と provider は同じ TROCCO（日本）を指す。特別なリージョン設定は不要。

## import ブロックのアドレス生成規則

`import { to = <tf_type>.<addr>, id = "<id>" }` の `<addr>` は HCL 識別子。GET で得た `name` から生成:

- `[^a-zA-Z0-9_]` → `_` に置換
- 先頭が数字なら `r_` を前置
- 空になったら `res_<id>`
- 重複したら末尾に `_<id>` を付けて一意化

## generate-config-out の制約（best-effort・要レビュー）

生成される HCL は Terraform 純正だが完全ではない。以下を理解して使う:

- **参照ではなくリテラル id で出る**。`resource_group_id = 45`、`bigquery_connection_id = 1` のように
  数値がそのまま入る（`trocco_resource_group.x.id` のような参照にはならない）。必要なら手動で参照に置換。
- **接続情報 `trocco_connection` は対象外**。転送/データマート/dbt は接続を `connection_id`（数値）で参照するが、
  その接続リソース自体はこの skill では出力しない。apply するなら別途用意/参照解決が必要。
- **秘匿情報は含まれない**（設計どおり安全）。dbt Git リポジトリは公開鍵のみ、接続の資格情報は API に出ない。
- **巨大リソースは冗長・要手直し**。`trocco_job_definition` の入出力オプションなど、
  optional/computed 属性が多く出て手直しが要る場合がある。
- **生成直後の plan が no-op にならないことがある**。実測では転送設定で次が出た。

  ```
  Plan: 2 to import, 0 to add, 1 to change, 0 to destroy.
  ```

  原因は `filter_columns[].default` で、API は空文字 `""` を返すのに生成 HCL は `default = null` を出す。
  `"" != null` なので恒久的な差分になる。`null` を `""` に直すと no-op になることを確認済み。

  ```bash
  sed -i '' 's/default                      = null/default                      = ""/' generated.tf
  ```

  **生成後は必ず `terraform plan` を流し、`0 to change` になるか確認する**。差分が残る場合は
  「生成物が不完全」であって設定が変わったわけではない。差分の中身をユーザーに提示して判断を仰ぐ。
  BigQuery データマートは実測で no-op になった。
- **provider が未対応の属性は黙って落ちる。しかも plan は no-op になるので気付けない**。
  実測（ワークフロー）: API は HTTP 通知を返すのに、生成 HCL では宛先と本文が消えた。

  ```jsonc
  // API のレスポンス
  {"type":"job_execution","destination_type":"http",
   "http_config":{"notification_id":4,"message":"{\"text\": \"hello\"}"}}
  ```

  ```hcl
  # 生成された HCL（http_config が無い）
  { destination_type = "http", email_config = null, slack_config = null, ... }
  ```

  `trocco_pipeline_definition` の通知は `email_config` / `slack_config` しか持たず、
  HTTP 通知に対応する属性が provider に存在しないため（v0.36.0 時点）。
  それでも `terraform plan` は **`0 to change`** を返す。**no-op は「完全にエクスポートできた」証明にならない**。

  対策として、**API のレスポンスと生成 HCL を突き合わせる**。特に `notifications` は
  件数と `destination_type` を照合し、落ちているものがあればユーザーに報告する。

  ```bash
  trocco-api.sh "/pipeline_definitions/$id" | jq -c '[.notifications[]?|.destination_type]'
  grep -c 'destination_type' generated.tf
  ```

- したがって**生成物は必ず目視レビューしてから `apply`** する。この skill 自体は `apply` しない。

## ワークフローは Terraform 経由なら往復できる

生の API はワークフローの GET 結果を PATCH に投げ返せない（`tasks[].key` が返らず
`task_dependencies` が整数で返るため。workflows.md 参照）。一方 **provider はこれを吸収する**。
実測では `task_identifier` を文字列化した値を `key` として出力し、`task_dependencies` も同じ文字列で結んでいた。

```hcl
tasks = [ { key = "3", ... }, ... ]
task_dependencies = [ { source = "2", destination = "3" }, ... ]
```

条件分岐・データチェック・通知・dbt・データマートなど複数種別のタスクを含むワークフローでも、
生成後の plan が no-op になることを確認した。ワークフロー構成をコードで管理したい場合は、API を直接叩くより
Terraform を経由するほうが扱いやすい。

## 出力レイアウト

`-generate-config-out` は 1 実行につき 1 ファイル。

- **単一ファイル**: すべての import を 1 つの `imports.tf` に入れ、1 回で `-generate-config-out=<file>`。
- **タイプ別分割**: 種別ごとに import サブセットを用意し、`-generate-config-out=<dir>/<type>.tf` を種別数だけ実行。

## 関連

- 認証・ページング・共通ルール: [`trocco-api.md`](./trocco-api.md)
- 各リソースのスキーマ: [`workflows.md`](./workflows.md) / [`datamart-write-modes.md`](./datamart-write-modes.md) /
  [`resource-groups.md`](./resource-groups.md) / [`teams.md`](./teams.md)
