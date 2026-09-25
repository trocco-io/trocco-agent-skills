# trocco-agent-skills

TROCCO の運用業務を、AI エージェント（Claude Code / Codex）と TROCCO API で半自動化する skill 集です。
通知やリソースグループの棚卸し、洗い替えから差分転送への切り替え、命名規則の統一、Terraform エクスポートなどをまとめて任せられます。

> [!IMPORTANT]
> 本リポジトリは TROCCO の公式機能ではなく、実験的なプロジェクトです。予告なく変更・廃止される場合があります。
> 変更系の操作（リネーム・設定変更・削除など）は、内容を確認のうえ実行してください。

## セットアップ

1. API キーをトークンファイルに置きます。

   ```bash
   mkdir -p ~/.config/trocco
   printf '%s' '＜あなたのAPIキー＞' > ~/.config/trocco/token
   chmod 600 ~/.config/trocco/token
   ```

   環境変数 `TROCCO_API_KEY` でも動きますが、その場合はエージェントがキーの値を読めます。
   1Password から読み込む方法もあります。詳細は [API キーの保護](docs/api-key-protection.md) を参照してください。

2. skill をインストールします。[apm](https://github.com/microsoft/apm) を利用します。

   ```bash
   apm install trocco-io/trocco-agent-skills --target claude   # Codex の場合は --target codex
   ```

   このリポジトリを clone し、`.apm/skills/<name>/` をお使いのエージェントのスキルディレクトリ
   （`.agents/skills/` など）へ直接コピーしても利用できます。

3. `curl` と `jq` が使えることを確認します。`export-terraform` を使う場合は Terraform 1.5 以上も必要です。

API は付属のラッパー `trocco-api.sh` 経由で呼び出します。ベース URL と認証ヘッダーはラッパーが
所有するため、エージェントが API キーの値を参照する必要はありません。
ラッパーは各スキルに `scripts/trocco-api.sh` として同梱されており、エージェントが場所を解決して使います。

セットアップの確認（インストール先は `--target` によって `.claude/` か `.agents/` に変わります）:

```bash
bash .claude/skills/audit-2fa/scripts/trocco-api.sh '/job_definitions?limit=10'
```

## アップデート

skill は随時更新します。TROCCO 本体の仕様変更への追従、skill の追加、記述の誤りの修正や
精度向上のための加筆などがあるため、新しく追加された skill を使いたいときや、
skill の動作が現在の TROCCO と合わないと感じたときに更新してください。

```bash
apm update --dry-run      # 何が変わるかを確認する
apm update                # 更新する（対話プロンプトが出ない環境では --yes を付けます）
```

apm がリモートから取得するため、リポジトリを clone しておく必要はありません。
`.apm/skills/` を手でコピーして使っている場合は、コピーし直してください。

## 使い方

「TROCCO で、通知が無い定義に通知をつけて」のように自然文で依頼すると、対応する skill が起動します。

## Skill 一覧

skill 名は `カテゴリ-` prefix で名前空間化しています。

- `audit-` … 棚卸し・診断（読み取り主体、是正は提案）
- `govern-` … 統制の整備（通知/リソースグループ/説明の付与、命名規則の統一）
- `optimize-` … コスト・パフォーマンスの最適化
- `export-` … IaC / エクスポート

| Skill | 何をするか | 主な操作 |
|---|---|---|
| [`audit-2fa`](.apm/skills/audit-2fa/SKILL.md) | 二段階認証が未設定のユーザーと、未ログインのまま残る招待を棚卸し | 検出 + 削除（要確認） |
| [`audit-stale-teams`](.apm/skills/audit-stale-teams/SKILL.md) | 利用実態が薄いチームを棚卸し・統合支援 | 検出 + 変更（要確認） |
| [`audit-stale-resource-groups`](.apm/skills/audit-stale-resource-groups/SKILL.md) | チームも定義も紐づかないリソースグループを棚卸し | 検出 + 変更（要確認） |
| [`govern-notifications`](.apm/skills/govern-notifications/SKILL.md) | 通知が無い定義を洗い出し、指定の通知を付与 | 検出 + 変更（要確認） |
| [`govern-resource-groups`](.apm/skills/govern-resource-groups/SKILL.md) | リソースグループ未設定の定義に割り当て | 検出 + 変更（要確認） |
| [`govern-descriptions`](.apm/skills/govern-descriptions/SKILL.md) | 説明が無い定義に、処理内容の説明文を生成して付与 | 検出 + 変更（要確認） |
| [`govern-naming`](.apm/skills/govern-naming/SKILL.md) | 命名規則を導出・確認し、非準拠の定義名を一括リネーム | 検出 + 変更（要確認） |
| [`optimize-transfer-incremental`](.apm/skills/optimize-transfer-incremental/SKILL.md) | 洗い替えの転送設定を差分転送へ切り替え | 検出 + 変更（要確認） |
| [`optimize-datamart-incremental`](.apm/skills/optimize-datamart-incremental/SKILL.md) | 洗い替えの BigQuery データマートを増分更新 / SCD Type 2 へ切り替え | 検出 + 変更（要確認） |
| [`optimize-workflow-consolidation`](.apm/skills/optimize-workflow-consolidation/SKILL.md) | 個別スケジュールの定義をワークフローへ集約 | 提案 + 変更（要確認） |
| [`export-terraform`](.apm/skills/export-terraform/SKILL.md) | 既存リソースから Terraform Provider 準拠の `.tf` を生成 | 列挙 + HCL 生成 |

## 安全に使うために

- **読み取りは自由・変更は必ず確認しましょう**。検出や一覧（GET）は自由に実行し、PATCH / POST / DELETE などの変更系は、対象と before/after を提示して承認を得てから実行します。
- まず少数の開発用の設定などで試し、問題がなければ横展開しましょう。
- 再実行しても二重適用にならないよう、適用前に設定済みかを判定しましょう。
- API キーの取り扱いは [API キーの保護](docs/api-key-protection.md) を参照してください。

## ドキュメント

- [API キーの保護](docs/api-key-protection.md): 3 方式の設定手順と API キーの漏洩防止プロセスについて記載しています。
- [`knowledge/`](knowledge/): 各 skill が参照する、TROCCO API を利用するうえでのリファレンスです。
  skill の実行時にエージェントが読むため、利用するだけであれば目を通す必要はありません。
  内部の挙動を確認したい場合や skill を追加したい場合に参照してください
  （TROCCO API の共通仕様は [`trocco-api.md`](knowledge/trocco-api.md) にあります）。
  ここと `bin/trocco-api.sh` が単一ソースで、各 skill の `references/` と `scripts/` へは
  `scripts/sync-references.sh` が複製します（`--check` で同期ずれを検査できます）。

TROCCO API の一次情報は公式ドキュメント https://documents.trocco.io/apidocs.md です（URL 末尾に `.md` を付けると Markdown で取得できます）。
本リポジトリのナレッジは執筆時点の要約のため、記載が異なる場合は公式ドキュメントを正とします。

## ライセンス

[MIT License](LICENSE) © primenumber Inc.
