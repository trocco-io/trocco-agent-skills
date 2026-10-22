# ジョブの定義の現況を取得する

失敗原因をログで特定したあと、**修正を提案する前に定義の現況を取得して突き合わせる**。
ログだけでは「どの設定をどう変えるか」まで言えないことが多く、再実行してよいかも書き込みモードを見ないと判断できない。

## ジョブから定義へ

| ジョブ | 実行結果の定義 ID | 定義の詳細 |
|---|---|---|
| 転送ジョブ | `job_definition_id` | `GET /job_definitions/:id` |
| データマートジョブ | `datamart_definition_id` | `GET /datamart_definitions/:id` |
| dbt ジョブ | `dbt_job_definition_id` | `GET /dbt_job_definitions/:id` |

- 定義の作成日時・更新日時は、詳細ではなく**一覧**（`GET /job_definitions?name=...` など）の `created_at` / `updated_at` で取れる。
- 転送設定は一部のコネクタで詳細が 400（未サポート）になる（trocco-api.md「詳細取得（show）が 400 になるコネクタがある」参照）。その場合はログと一覧の情報だけで判断する。
- 取得するのは**現在の**設定であり、失敗したジョブの実行時点の設定ではない。定義の `updated_at` が失敗より後なら、
  その後に誰かが設定を変えている。報告にその旨を添える。

## 見る項目

ログのエラーに関係する項目だけを見る。全量を読まない・貼らない。

| 見たいこと | 転送設定 | データマート定義 |
|---|---|---|
| 再実行してよいか | `output_option.<転送先>_output_option.mode` | `datamart_<DWH>_option.write_disposition` |
| 取得対象 | `input_option.<転送元>_input_option` の `query` / テーブル / パス / URL など | `datamart_<DWH>_option.query`（実行時の展開後は実行結果の `executed_query`） |
| 列定義とのずれ | `input_option.<転送元>_input_option.input_option_columns`、`filter_columns` | |
| カスタム変数 | 定義直下と `input_option.<転送元>_input_option` の両方にありうる `custom_variable_settings` | `custom_variable_settings` |
| 接続先 | `*_connection_id`（接続情報の中身は見ない） | `*_connection_id` |

キー名はコネクタで変わる。まず `jq '.input_option | keys'` のように 1 段ずつ構造を確かめてから掘る。

> [!CAUTION]
> **生の定義を AI の入力に入れない**。定義にはクエリ・URL・ファイルパスのほか、ヘッダー・リクエストパラメータ・
> カスタム変数の値としてトークンが直書きされていることがある。`troubleshoot-job-logs` では、
> `fetch-job-logs.sh` が定義の詳細も取得し、`redact.sh json` で伏せ字にしたもの（`definition.json`）だけを読む
> （認証情報らしいキーは常に `‹secret›`、`mode` などの列挙値はそのまま、他の文字列は許可リスト方式）。
> クエリの全文や列名など具体的な値が要るときは、ユーザーの許可を得てから必要な行だけを `redact.sh mask` で見る（job-logs.md 参照）。

## よくある突き合わせ

- **`SELECT *` と列定義のずれ**: クエリが `SELECT *` で、列定義（`input_option_columns`）に無い列が転送元にあると、
  その列の型が原因で落ちることがある（未対応型など）。列を明示した SELECT にするか、該当列を CAST する提案になる。
- **カスタム変数で中身を差し込む設定**: リクエストボディ・クエリ・パスがカスタム変数（例: `$body$`）だけでできている場合、
  失敗の原因は**実行時に渡された値**にある。ワークフローや API 実行から渡された値は、ジョブ結果 API では見えない。
  定義に入っている値は既定値にすぎないので、呼び出し元（ワークフローの設定、そこで使うクエリの結果）を確認するよう案内する。
- **作成以来一度も成功していない定義**: 定義の `created_at` 以降に成功が無ければ、作成時の設定不備を疑う。
  `updated_at` が作成後にあれば、直そうとして直っていない可能性がある。
- **失敗し始めた直前の更新**: 定義の `updated_at` が最初の失敗の直前なら、その変更が原因の候補。
  ただし API では変更前の設定（履歴）は取れないので、画面のリビジョン履歴で確認してもらう。

## 副作用のある転送元

転送元が HTTP・HTTPS で `method` が `POST` / `PUT` / `PATCH` / `DELETE` の定義は、**転送元の API に書き込んでいる**
（例: SaaS への登録・更新を TROCCO から呼び出し、その応答を転送先に保存する使い方）。
このような定義の再実行は、転送先ではなく**転送元のサービス側で二重登録・二重更新**を起こしうる。
書き込みモードが洗い替えでも再実行が安全とは限らないので、相手先 API の冪等性を確認するよう添える。
