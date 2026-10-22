# ジョブの実行結果・実行ログの取得

> 2026-10-20 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

転送・データマート・dbt ジョブは、**実行ログ（エラーログを含む）を API で取得できる**。
失敗したジョブの原因調査は、画面を開かずに API だけで完結する。

## エンドポイント

| ジョブ種別 | 実行結果 | 実行ログ | 画面の URL |
|---|---|---|---|
| 転送ジョブ | `GET /jobs/:job_id` | `GET /jobs/:job_id/logs` | `https://trocco.io/jobs/:id` |
| データマートジョブ | `GET /datamart_jobs/:id` | `GET /datamart_jobs/:id/logs` | `https://trocco.io/datamart/jobs/:id` |
| dbt ジョブ | `GET /dbt_jobs/:id` | `GET /dbt_jobs/:id/logs` | `https://trocco.io/dbt_jobs/:id` |
| ワークフロージョブ | `GET /pipeline_jobs/:id` | **なし** | `https://trocco.io/pipeline_jobs/:id` |

- 公式リファレンス:
  [転送](https://documents.trocco.io/apidocs/get-job-logs.md) /
  [データマート](https://documents.trocco.io/apidocs/get-datamart-job-logs.md) /
  [dbt](https://documents.trocco.io/apidocs/get-dbt-job-logs.md)
- **ジョブ ID は種別ごとに別の採番**。同じ数字の転送ジョブとデータマートジョブが両方存在しうる。
  数字だけを渡されたときに別の種別へ「ついでに」問い合わせると、無関係なジョブのログを読んでしまう。
  種別が分からないときはユーザーに確認する（URL を貰えば種別が確定する）。
- ワークフロージョブはログを取れない。下記「ワークフロージョブが失敗したとき」を参照。

## ワークフロージョブが失敗したとき

`GET /pipeline_jobs/:id` が返すのは、ワークフロージョブ全体のステータスと時刻だけ。
**どのタスクが失敗したか、各タスクの結果、各タスクが作ったジョブの ID は、API では分からない**。
ワークフロージョブの ID（`https://trocco.io/pipeline_jobs/:id`）を渡されたときや、
「ワークフローが落ちた」と依頼されたときは、次のように進める。

1. `GET /pipeline_jobs/:id` でステータス・開始/終了時刻・`pipeline_definition_id` を示す。
2. **実際に失敗したタスクのジョブ ID（できればジョブ画面の URL）をユーザーに依頼する**。
   ワークフロージョブの詳細画面で失敗したタスクを開くと、そのタスクが実行したジョブの画面に移れる。
   - 必要なのは「タスクが実行したジョブ」の ID。ワークフロー定義内のタスクの識別子（`task_identifier`）ではない。
   - URL を貰えばジョブ種別も確定する（数字だけだと種別を取り違えるおそれがある。上記「ジョブ ID は種別ごとに別の採番」）。
3. 失敗したタスクの種別に応じて、ログを取れるかが決まる。

| タスク種別（`tasks[].type`） | 実行されるジョブ | ログ取得 |
|---|---|---|
| `trocco_transfer` | 転送ジョブ | ✅ `GET /jobs/:job_id/logs` |
| `trocco_bigquery_datamart` / `trocco_snowflake_datamart` / `trocco_redshift_datamart` / `trocco_databricks_datamart` | データマートジョブ | ✅ `GET /datamart_jobs/:id/logs` |
| `trocco_dbt` | dbt ジョブ | ✅ `GET /dbt_jobs/:id/logs` |
| `trocco_pipeline` | 子ワークフローのジョブ | ✕ 子ワークフローの失敗タスクについて、同じ手順を繰り返す |
| データチェック・HTTP リクエスト・Slack 通知・Tableau 抽出・条件分岐など | 上記以外 | ✕ API では取れない。画面で確認してもらう |

失敗したタスクが転送・データマート・dbt なら、そのジョブ ID でログを取得して原因を調べられる。

> [!NOTE]
> ユーザーがタスクのジョブ ID を用意できないときの補助手段（**推定**であり、確認を取ってから使う）:
> `GET /pipeline_definitions/:pipeline_definition_id` で `tasks[]` の参照先定義（`<type>_config.definition_id`）を得て、
> 転送タスクに限り `GET /job_definitions/:definition_id/jobs?start_time=...&end_time=...&time_zone=Asia/Tokyo` を
> ワークフロージョブの実行時間帯で絞り、`executor_type == "workflow"` かつ失敗したジョブを探す
> （日時は `2026-10-01 09:00:00` 形式。空白は `%20` にエンコードする。`time_zone` の既定は `Asia/Tokyo`）。
> 同じ定義を別のワークフローや手動実行が同時に動かしていると取り違えるため、候補はユーザーに確認してもらう。
> データマート・dbt にはジョブ一覧 API が無いので、この方法では探せない。

## レスポンス

```json
{
  "job": { "id": 123, "job_definition_id": 321, "status": "error" },
  "logs": {
    "streams": [
      { "type": "log",       "status": "available", "content": "2026-10-01 ...\n...", "truncated": false, "byte_size": 48213 },
      { "type": "error_log", "status": "available", "content": "...",                "truncated": false, "byte_size": 2048 }
    ]
  }
}
```

- `job` の定義 ID のキー名は種別で変わる（`job_definition_id` / `datamart_definition_id` / `dbt_job_definition_id`）。
- `logs.streams[]` の種別:
  - 転送ジョブ: `log`（実行ログ）と `error_log`（エラーログ）の 2 本。この順で返る。
    クエリ `?type=log` / `?type=error_log` で 1 本に絞れる。それ以外の値は 400。
  - データマート・dbt ジョブ: `log` の 1 本のみ（エラーログに相当するものは無い）。`type` での絞り込みは受け付けない。

### `logs.streams[].status`

| 値 | 意味 | 対処 |
|---|---|---|
| `available` | 取得できた | `content` を読む |
| `pending` | ジョブが完了しておらず、まだ出力されていない | 実行結果 API でステータスを見て、完了後に取り直す |
| `empty` | ジョブは完了しているが、この種別のログは出力されなかった | 転送の `error_log` が `empty` なのは正常（エラーが無かった等）。もう一方を読む |
| `expired` | 保持期間（約 1 年）を過ぎた | 取得不可。ユーザーに伝える |

`available` 以外のとき `content` は空文字。状態はストリームごとに判定されるので、
`type` で絞っても同じストリームの `status` は変わらない。

### 長いログの切り詰め

- ログが一定量を超えると**先頭と末尾だけ**が返り、中間は `skipped...` の 1 行に置き換わる。
  このとき `truncated: true`。
- 失敗の直接原因はたいてい末尾にあるので、末尾が残っていれば原因調査には足りることが多い。
  ただし**最初に起きたエラーや警告が中間に埋もれて見えない**ことがある。
  `truncated: true` のときは、その旨を報告に添える。全文が必要なら画面からダウンロードしてもらう。
- 1 行が極端に長い場合（巨大な SQL やレコード値の出力など）は、行の途中で切られていることがある。

### その他の挙動

- 実行中のジョブは、取得した時点までのログを返す。**前回からの差分だけを取る手段は無い**。
- 取得に一時的に失敗すると **503** と `Retry-After`（秒）が返る。2 本のうち 1 本だけ失敗した場合も
  全体が 503 になる（片方だけ返して「ログが空だった」と誤認させないため）。時間を置いて再試行する。
- 権限が無い定義のジョブ、アーカイブ（削除）済みの定義のジョブは **404**（存在自体を伏せる）。
- ラッパーの 429 自動リトライは効くが、503 は自動リトライされない。

## 実行結果 API から分かること

ログを読む前に実行結果を取ると、何のジョブがいつどう終わったかを先に押さえられる。

| 項目 | 転送 | データマート | dbt | 使い道 |
|---|---|---|---|---|
| 定義名 | `job_definition_name` | `datamart_definition_name` | `dbt_job_definition_name` | 報告の主語 |
| `status` | ✅（`timeout` あり） | ✅ | ✅ | `timeout` / `canceled` はログに例外が出ないことがある |
| `executor_type` | ✅ | ✅ | ✅ | 手動 / スケジュール / ワークフロー / API / 実行トリガー |
| `context_time` | ✅ | ✅ | ✅ | 時刻・日付のカスタム変数の展開基準 |
| `started_at` / `finished_at` | ✅ | ✅ | ✅ | 所要時間。タイムアウトの判断材料 |
| 件数 | `transfer_record` / `transfer_byte` / `skipped_row_count` | `transfer_record` | なし | 0 件・スキップ行の有無 |
| その他 | | `executed_query`（展開後のクエリ全文）, `pipeline_job_id` | `dbt_job_definition_revision_id` | |

- 転送ジョブだけは `GET /job_definitions/:id/jobs` でジョブ一覧を取れる。
  「いつから失敗しているか」「前回は成功していたか」を確認できる。データマート・dbt には一覧 API が無い。
  使い方と注意（1 回 100 件まで・新しい順）は [`job-search.md`](./job-search.md) を参照。
- 修正を提案する前に、定義の現況を取得して突き合わせる（[`job-definition-context.md`](./job-definition-context.md)）。
- `executed_query` は巨大になりうる。表示するときは必要部分だけ切り出す。

## ログの扱い方: 伏せ字にしてから読む

実行ログには接続先のホスト名・ユーザー名・ファイルパス・クエリ・データの値が含まれうる（下記「取り扱いの注意」）。
**生のログを AI の入力に入れない**。読んでから報告で伏せるのでは遅い。

`troubleshoot-job-logs` skill は、取得から伏せ字化までを同梱のスクリプトで行う。

| スクリプト | 役割 |
|---|---|
| `fetch-job-logs.sh <jobs\|datamart_jobs\|dbt_jobs> <id> [dir]` | 実行結果・実行ログ・定義の詳細を取得し、生データは `<dir>/.raw/`（権限 600）へ、伏せ字にしたものを `<dir>/` 直下へ置く |
| `redact.sh allow <file>` | 許可リスト方式。どの顧客でも同じになる文字列だけを残し、他は `‹…›`。行番号付き |
| `redact.sh mask <file> <start> <end>` | ユーザーの許可を得て一部の行だけを見るとき用。ホスト名・URL・メール・IP・パス・認証情報らしい値・長い ID を伏せる（テーブル名・列名などは残る） |
| `redact.sh json <file>` | 定義の詳細用。認証情報らしいキーは常に `‹secret›`、列挙値（`mode` など）はそのまま、他の文字列は許可リスト方式 |

許可リスト方式で残るもの: エラー文の一般的な英単語、SQL / HTTP の用語と型名、Java の例外クラス名とスタックトレースの位置、
エラーコードらしい形（`RESOURCE_EXHAUSTED`, `ParameterMissing`, `invalid_grant` など）、5 桁以下の数字、カスタム変数のプレースホルダー（`$name$`）。
ホスト名・ユーザー名・テーブル名・列名・日本語の文字列・長い ID・Cookie は消える。

実例では、許可リスト方式だけで次の手掛かりが残り、原因を特定できた。

- `HttpException ... code=400 ... "ParameterMissing" ... Parameter Invalid ‹…› is required` と、定義のリクエストボディが `$body$` だけであること
- `RESOURCE_EXHAUSTED: Quota exceeded ... 'Read requests per minute'`
- `Unsupported type LONGBLOB (sqlType=-4) of '‹…›' column` と、定義のクエリが `SELECT *` で列定義が 6 列であること

伏せ字になった語（どの列か、どのパラメータか）が修正提案に必要なときだけ、行番号と理由を示して許可を得てから `mask` で見る。

### 伏せ字済みのログの読み方

全文を一度に読まない。行数を確認し、根本原因の行を探してから前後を読む。各行の先頭に元のログの行番号が付いている。

```bash
wc -l "$out"/*.txt
grep -E 'Caused by:|\]: Error:|Exception:' "$out"/log.txt "$out"/error_log.txt | cut -c1-400 | tail -20
tail -n 40 "$out/log.txt"
```

`[ERROR]` での grep は警告でほぼ埋まることがあるので、まず `Caused by:` / `Error:` / 例外名に絞る。

### どこに原因が書かれているか

- **転送ジョブ**: 転送処理は Embulk で動く。
  - **根本原因は `log` と `error_log` のどちらに出るか決まっていない**。両方から `Caused by:` と、
    末尾近くの `Error:` で始まる行（Embulk が最後に出す要約）を探す。
  - `error_log` は標準エラー出力で、**無害な警告も `[ERROR]` 付きで大量に出る**（HTTP クライアントの Cookie 警告、
    Ruby の warning など）。`[ERROR]` の行数や先頭の行で判断しない。
  - Java の例外は外側から内側へ `Caused by:` が連なる。**最後の `Caused by:` が根本原因**であることが多い。
    `PartialExecutionException` / `RetryGiveupException` などの外側の例外名だけで判断しない。
    接続先が返したステータスコードと本文（例: `code=400, body={...}`）が最後の `Caused by:` に載っていることが多い。
  - スタックトレースに `EmbulkRunner.preview` が出ていれば、転送前のスキーマ確認の段階で落ちている（データは書かれていない）。
    列の型（未対応型）や列定義とのずれが典型。
  - 接続エラー（タイムアウト・認証失敗・名前解決失敗）、権限不足、スキーマ不一致（型変換・カラム不足）、
    レコード単位のパースエラー（`skipped_row_count` と併せて見る）が典型。
- **データマートジョブ**: 実行したクエリ（カスタム変数の展開後）と、DWH が返したエラーメッセージが出る。
  エラー行に出る行番号・カラム名を `executed_query` と突き合わせる。
- **dbt ジョブ**: dbt の標準出力がそのまま出る。末尾のサマリー
  （`Done. PASS=.. WARN=.. ERROR=.. SKIP=.. TOTAL=..`）で失敗件数を掴み、
  `Database Error in model ...` / `Compilation Error` / `Failure in test ...` の行から失敗したモデル・テストを特定する。

原因を特定したら、打ち手（設定修正 / 問い合わせ / リトライ）を [`job-failure-triage.md`](./job-failure-triage.md) で判定する。
エラー文字列の意味は、ヘルプセンターをその場で検索して確かめる（[`help-center-search.md`](./help-center-search.md)）。

## 取り扱いの注意（公式ドキュメントの注意事項の要約）

- 実行ログには、接続先のホスト名・ユーザー名・ファイルパス・実行したクエリ・エラーになったデータの値などが含まれうる。
- 接続情報に保存したパスワードやトークンを TROCCO がログに書き出すことは無い。ただし、HTTP・HTTPS 転送元で
  マスキングしていないパラメータ、クエリやカスタム変数・dbt プロジェクトに直接書いた値、
  接続先サービスがエラーメッセージに含めた値は、そのまま含まれる場合がある。
- ログを AI サービスに渡すときは、入力データが学習に使われない設定で利用し、所属組織のデータ取り扱い方針を確認する。
- 報告にログを引用するときは、伏せ字済みの行を必要な分だけにとどめる。
  保存したログファイルは調査が終わったら削除する。
