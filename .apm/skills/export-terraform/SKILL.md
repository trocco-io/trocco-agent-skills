---
name: export-terraform
description: 既存の TROCCO リソース（転送設定・BigQueryデータマート・ワークフロー・dbtジョブ/Gitリポジトリ・リソースグループ・チーム）を GET API で読み取り、TROCCO Terraform Provider 準拠の .tf を生成する。「Terraformに書き出して」「tfファイルにエクスポート」「既存資産をTerraform管理下に」と依頼されたときに使う。
---

# TROCCO リソースを Terraform (.tf) にエクスポート

既存リソースを TROCCO API の GET で列挙し、`import {}` ブロック + `terraform plan -generate-config-out` で
provider 準拠の `.tf` を生成する。GitOps 移行の on-ramp。**変更（apply）はしない**。

## 大原則: API はラッパー `trocco-api.sh` 経由で呼ぶ

`curl` で直接叩かない。ベース URL と `Authorization` ヘッダーはラッパーが所有するので、
**パス以降と curl 引数だけ**を渡す（API キーの値を読む必要はない）。

ラッパーの置き場所は導入方法によって変わる。まず次でパスを確定する。

```bash
# ls はエイリアス（-F 等）で表示が変わることがあるため使わない
for p in {.claude,.agents}/skills/export-terraform/scripts/trocco-api.sh bin/trocco-api.sh; do
  [ -f "$p" ] && echo "$p" && break
done
```

以降この SKILL.md と `references/` に出てくる `trocco-api.sh` は、確定したパスに読み替えて実行する。
コマンドごとにシェルは切り替わるため、変数には入れず毎回フルパスで書く。

```bash
bash .claude/skills/export-terraform/scripts/trocco-api.sh "/job_definitions?limit=200"   # パスは確定した値に置き換える
```

## 前提知識（必ず先に読む）
- [`knowledge/trocco-api.md`](./references/trocco-api.md): 認証・ページング・共通ルール
- [`knowledge/terraform-export.md`](./references/terraform-export.md): 方式・リソース対応表・制約・アドレス規則

## 手順

### 1. 前提チェック（読み取りのみ）
- `terraform version`（**1.5 以上**必須。無ければ導入案内して中断）。
- **Terraform へのキーの渡し方を決める**。ラッパーの資格情報は Terraform に引き継がれない。
  provider は環境変数 `TROCCO_API_KEY` しか読まないため、トークンファイルや 1Password を
  使っている場合は `terraform` コマンドに限って渡す（値は出力しない）。
  具体的な渡し方は [`knowledge/terraform-export.md`](./references/terraform-export.md)「Provider 設定」を参照。

### 2. 対象の解決（GET API＝読み取りのみ）
サポートする選択方法は 2 つ:
- **ID 直接指定**: `<type>:<id,...>`（例 `job_definition:123,456` / `team:28`）。
  各 `GET /api/<collection>/<id>` で存在と `name` を確認。
- **ラベル/名前パターン**: 対象 collection を全ページ取得（`{items,next_cursor}`・空配列キー省略に注意）し、
  `name` 部分一致 or `labels` 一致でフィルタ。

対応表（種別 → tf リソース → collection）は [`terraform-export.md`](./references/terraform-export.md) 参照。
データマートは **BigQuery のみ**（`data_warehouse_type=bigquery` で絞る。Snowflake/Redshift は対象外と明示）。

解決結果を「**種別 / id / name**」の表でユーザーに提示し、**この対象で良いか確認**する。

**データマートは事前に `data_warehouse_type` で分離する**（provider に対応リソースがあるのは BigQuery のみ）:

```bash
# BigQuery 以外（対象外）を先に洗い出して報告する
fetch_all datamart_definitions \
  | jq -r 'select(.data_warehouse_type!="bigquery") | "対象外(\(.data_warehouse_type)): id=\(.id)\t\(.name)"'
```

対象外の件数は必ず報告する（例: 「Snowflake データマート 3 件は Terraform Provider に対応リソースが無いため対象外」）。
`show` 非対応コネクタ（例 `custom_connector` ソース）で 400 のものは name 解決できないが、import には id のみで足りる。
name 未解決は id 表示にフォールバックして報告。

### 3. 生成用ワークスペース作成
作業ディレクトリ（ユーザー指定 or 一時）に:
- `provider.tf`: `required_providers { trocco = { source = "trocco-io/trocco", version = "~> 0.33" } }` +
  `provider "trocco" {}`（api_key は環境変数 `TROCCO_API_KEY` で解決）。
- `imports.tf`: 各対象に `import { to = <tf_type>.<addr>, id = "<id>" }`。
  `<addr>` は name をサニタイズ＋一意化（規則は [`terraform-export.md`](./references/terraform-export.md)）。

### 4. HCL 生成
- `terraform init`。
- **出力レイアウトを実行時にユーザーへ確認**:
  - 単一ファイル → `terraform plan -generate-config-out=<指定ファイル>` を 1 回。
  - タイプ別分割 → 種別ごとに import サブセットで `-generate-config-out=<dir>/<type>.tf` を複数回。
- 生成後、件数・出力パス・警告を報告。

### 4.5 生成物の plan が no-op か確認する
生成しただけで終わらせない。`terraform plan` を流し `0 to change` になるか確認する。

実測では転送設定で `1 to change` が出た。`filter_columns[].default` が API では空文字なのに
生成 HCL は `null` を出すためで、設定が変わったわけではない。`null` を `""` に直すと no-op になる。
差分が残る場合は中身をユーザーに提示し、生成物の不備か実際の差異かを判断してもらう。

> [!CAUTION]
> **no-op は「完全にエクスポートできた」証明にならない**。provider が未対応の属性は生成 HCL から
> 黙って落ち、それでも plan は `0 to change` になる。実測では、ワークフローの HTTP 通知の宛先と本文が
> 消えたまま no-op だった（provider に該当属性が無いため）。
>
> 生成後に **API のレスポンスと生成 HCL を突き合わせる**。特に `notifications` は件数と
> `destination_type` を照合し、落ちているものがあれば対象外として報告する。

### 5. レビュー案内（apply しない）
- 生成 HCL は **best-effort**: `resource_group_id`/`connection_id` は**リテラル id**（参照ではない）。
- **接続 `trocco_connection` は対象外**。apply するなら別途用意/参照解決が必要。
- 秘匿情報（deploy 秘密鍵・接続資格情報）は含まれない（設計どおり）。
- `terraform validate` で構文確認を促し、**apply 前に必ず目視レビュー**するよう案内。

## やってはいけないこと
- `terraform apply` を実行しない（列挙＋HCL 生成まで。state 取り込み/適用はユーザー判断）。
- 生成物をレビューせず正とみなさない（generate-config-out は不完全な HCL を出しうる）。
- API キーや生成物中の値をログ・コミットに残さない。
- 未対応リソース（Snowflake/Redshift データマート等）を対応済みのように扱わない。公式 docs で確認。
