# trocco-agent-skills: Agent Guide

このリポジトリは、TROCCO の運用業務を TROCCO API 経由で半自動化する skill 集。

## スキルの使い方

- 各スキルは自己完結で、必要な API リファレンス（`references/`）と API ラッパー
  （`scripts/trocco-api.sh`）を同じディレクトリに同梱している。どちらも canonical な
  `knowledge/` と `bin/` から `scripts/sync-references.sh` が生成する。編集は canonical 側で行う。
- カテゴリ（prefix）:
  - `audit-` … 棚卸し・診断（読み取り主体）
  - `govern-` … 統制の整備（通知/リソースグループ/説明の付与、命名規則の統一）
  - `optimize-` … コスト/パフォーマンス最適化（差分転送・増分更新・集約）
  - `export-` … IaC/エクスポート（Terraform）
- タスクに応じて該当スキルの `SKILL.md` を読み込み、その手順に従う。

## API キーの取り扱い（厳守）

- API は必ずラッパー経由で呼ぶ。`curl` で直接叩かない。
  ベース URL（`https://trocco.io/api`）と `Authorization` ヘッダーはラッパーが所有するので、
  パス以降と curl 引数だけを渡す。キーの値を読む必要はない。

  ```bash
  bin/trocco-api.sh '/job_definitions?limit=200'
  ```

  このリポジトリの中では `bin/` 版を使う。apm でインストールした利用者の環境には `bin/` が
  無く、各スキルの `scripts/trocco-api.sh` が呼ばれる（中身は同一）。

- キー値を `echo` / `printf` で出力しない。ファイルやコミットに残さない。
- `env` / `printenv` / `declare -p` などで環境変数をダンプしない。
- `curl` の `-v` / `--verbose` / `--trace` を使わない（ヘッダーがログに出る）。
- これらは PreToolUse hook でも block されるが、hook は失敗時に素通りすることがある。
  block されなかったことを許可の根拠にせず、規約そのものを守ること。

## 変更系操作の原則

- 読み取り（GET・一覧・診断）は自由に実行してよい。
- 変更系（PATCH/POST/DELETE、リネーム、設定変更、削除）は、対象と before/after を提示して
  ユーザーの承認を得てから、少数で試して段階的に適用すること。
