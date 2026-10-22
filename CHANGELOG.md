# 変更履歴

このプロジェクトの主な変更を記録します。バージョンは `apm.yml` の `version` と対応します。

## [0.2.0] - 2026-10-22

失敗したジョブを探して原因と打ち手を示す skill を追加しました。あわせて、TROCCO API の要約を現行の公式リファレンスに合わせ、
各 skill が読み込むナレッジを必要な分だけに絞りました。

### 追加

- `troubleshoot-failed-jobs`: 期間や転送設定・ワークフローを指定して転送ジョブの実行結果を取得し、失敗しているジョブを洗い出す。
  失敗の出方（作成以来一度も成功していない / ある時点から毎回 / 散発 / 回復済み）で分類する
- `troubleshoot-job-logs`: 転送・データマート・dbt ジョブの実行ログと定義の現況を取得し、失敗原因と打ち手
  （設定修正 / 問い合わせ / リトライ）を示す。ワークフローの失敗は、失敗したタスクのジョブを特定して調べる
  - 実行ログと定義は、同梱のスクリプトで伏せ字にしてからエージェントに読ませる。既定は許可リスト方式で、
    判断に足りないときだけ、ユーザーの許可を得て一部の行をマスキングして読む
  - エラーの意味は TROCCO ヘルプセンターをその場で検索して確かめる（記事の内容はナレッジに書き写さない）
- ナレッジ: `job-logs.md`（実行ログ API）、`job-search.md`（失敗ジョブの探し方）、`job-failure-triage.md`（打ち手の判定）、
  `job-definition-context.md`（定義の現況との突き合わせ）、`help-center-search.md`（ヘルプセンターの探し方）
- 漏洩ガード hook: 伏せ字にする前の生ログを直接読むコマンドを止める
- CI: 伏せ字化の回帰テスト、ラッパーのバージョンと `apm.yml` の一致の検査

### 変更

- `knowledge/trocco-api.md` を 2026-10-20 時点の公式 API リファレンスに合わせた。ジョブの実行ログ API を含むエンドポイントを追加
- `trocco-api.md` を全 skill 共通の部分と話題別（`trocco-api-update.md`: 更新時の挙動、`trocco-api-endpoints.md`: エンドポイント一覧）に分け、
  各 skill が必要な分だけを読み込むようにした
- API ラッパーが `User-Agent: trocco-agent-skills/<バージョン> (<skill 名>)` を付けて API を呼ぶようにした。
  TROCCO 側でこの skill 集経由の利用状況を把握するためのもので、API キーや個人を特定する情報は含まない

### 修正

- 漏洩ガード hook が、API キーを使わない `curl`（公式ドキュメント `documents.trocco.io` やヘルプセンターの取得、`-G` 付きの呼び出し）まで止めていた

### 謝辞

[@nkzsdy](https://github.com/nkzsdy) さんから、[記事へのコメント](https://zenn.dev/link/comments/c1ecfb512d92ee)で
「API の要約にジョブ実行ログ取得 API が載っておらず、エージェントが『API ではエラーログを取得できない』と誤判断する」という報告と、
[修正案](https://github.com/nkzsdy/trocco-agent-skills/compare/main...sync-api-reference)をいただきました。この報告が今回の変更の出発点です。
修正案のうち、転送設定一覧の `limit` の上限と実測値、データマート定義の `column_descriptions` の例外、エラーハンドリングの 400 / 401 の説明、
ジョブの実行結果 API がエラー理由を含まないことは、修正案から取り込んでいます。ありがとうございました。

## [0.1.0] - 2026-09-25

初回公開。棚卸し（`audit-`）、統制の整備（`govern-`）、最適化（`optimize-`）、IaC / エクスポート（`export-`）の 11 skill。

[0.2.0]: https://github.com/trocco-io/trocco-agent-skills/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/trocco-io/trocco-agent-skills/releases/tag/v0.1.0
