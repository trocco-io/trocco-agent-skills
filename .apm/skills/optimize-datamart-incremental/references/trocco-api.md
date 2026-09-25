# TROCCO API: 基礎知識

> 2026-09-09 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

すべての skill が前提とする、TROCCO API の共通仕様。
skill を実行する前に、まずこのファイルを読むこと。

## 認証とベース URL: ラッパー経由で呼ぶ

API は **`trocco-api.sh` 経由**で呼ぶ。`curl` で直接叩かない。
ベース URL（`https://trocco.io/api`。TROCCO は日本でのみ提供のため固定）と
`Authorization: Token <API_KEY>` ヘッダーは**ラッパーが所有する**ので、
呼び出し側は **パス以降と curl 引数だけ**を渡す。

ラッパーはスキルに同梱されており、置き場所は導入方法によって変わる。
実行中のスキルの `SKILL.md`「大原則」の手順でパスを確定し、
以下の例に出てくる `trocco-api.sh` はそのパスに読み替えること。

```bash
# 例: 転送設定一覧を取得
trocco-api.sh '/job_definitions?limit=100'

# 例: 更新（PATCH）
trocco-api.sh /job_definitions/123 -X PATCH \
  -H 'Content-Type: application/json' -d @payload.json
```

ラッパーが API キーを解決する（1Password / トークンファイル / 環境変数の順）。
**キーの値を読む必要はない。**

> [!IMPORTANT]
> **API キーの取り扱い（全エージェント共通の規約）**
> - キー値を `echo` / `printf` で**出力しない**、ファイルやコミットに**残さない**。
> - `env` / `printenv` / `declare -p` などで環境変数を**ダンプしない**。
> - `curl` の `-v` / `--verbose` / `--trace` を**使わない**（Authorization ヘッダーがログに出る）。
> - Claude Code と Codex では PreToolUse hook がこれらを機械的に block する。ただし
>   **hook は失敗時に素通りする（fail-open）**ため、hook の有無にかかわらず**規約として厳守**すること。

## ページネーション（cursor 方式）

一覧系エンドポイント（`index`）は cursor ベースのページネーション。

- クエリパラメータ: `limit`（既定 50 / 上限 200）, `cursor`
- レスポンス封筒: `{ "items": [...], "next_cursor": "<base64>" | null }`
- `next_cursor` が `null` になるまで繰り返し取得する。

```bash
# レスポンスは必ずファイル経由で jq に渡す（下記「制御文字」の注意を参照）
# 変数名に注意: zsh では `path` が `PATH` と連動する特殊変数のため使わない（下記の警告を参照）。
W=<確定したラッパーのパス>   # 例: .claude/skills/audit-2fa/scripts/trocco-api.sh
fetch_all() { # $1 = コレクション名 (例: job_definitions)
  local cursor="" api_path page="${TMPDIR:-/tmp}/_trocco_page.json"
  while : ; do
    api_path="/$1?limit=200"
    [ -n "$cursor" ] && api_path="$api_path&cursor=$cursor"
    bash "$W" "$api_path" > "$page"
    jq -c '.items[]?' "$page"
    cursor=$(jq -r '.next_cursor // empty' "$page")
    [ -z "$cursor" ] && break
  done
}
fetch_all job_definitions | jq -s '.' > "${TMPDIR:-/tmp}/job_definitions.json"
```

> [!CAUTION]
> **zsh では変数名 `path` を使わないこと（macOS の既定シェルは zsh）。**
> zsh の `path` は `PATH` と連動する特殊変数で、`local path=...` のように代入すると
> **その場で `PATH` が壊れ、`jq` や `bash` すら見つからなくなる**（bash では起きない）。
> 上記のように `api_path` など別名を使う。

> [!IMPORTANT]
> **レスポンスをシェル変数に入れて `echo ... | jq` しないこと。**
> 定義名やメモに**生の制御文字**（改行・タブ等）が含まれるアカウントが実在し、
> `resp=$(curl ...); echo "$resp" | jq` の形だと
> `jq: parse error: Invalid string: control characters ... must be escaped` で**全件が落ちる**。
> 上記のように **curl の出力を一旦ファイルに落として `jq -f`（ファイル引数）で読む**こと。

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

> ジョブ実行系: `/datamart_jobs`（create のみ）, `/job_definitions/:id/jobs`（index）, `/jobs/:id`, `/pipeline_jobs`。

## 更新（PATCH）の重要な挙動: 差分更新だが配列は洗い替え

`job_definition` / `datamart_definition` / `pipeline_definition` の更新はいずれも
**スカラー項目は差分更新（送った項目だけ変わる）／配列項目は洗い替え（送った配列で全置換）** という
セマンティクスを持つ。OpenAPI の記述より:

> 基本的に差分更新です。配列要素については洗い替えとなるため、すべての要素を指定する必要があります。
> 配列要素を空にしたい場合明示的に空配列を指定してください。

これが意味すること:

- **スカラー**（`resource_group_id`, `description`, `name` など）→ その項目だけ PATCH すれば OK。他項目は保持される。
  - 実測: `job_definition` に `description` だけを PATCH しても、`filter_columns` / `input_option` /
    `output_option` / `schedules` はすべて保持された。
- **配列**（`notifications`, `schedules`, `labels` など）→ 送った配列が既存を**全置換**する。
  - 通知を「追加」したい場合は **既存を GET → 配列に append → 全量を PATCH** する（既存通知を消さないため）。
  - `[]` を送ると全削除される。**未指定なら変更されない**（差分更新のため）。

> [!CAUTION]
> **この差分更新は上記 3 種の定義だけの話**。チームとリソースグループには当てはまらない。
>
> | エンドポイント | PATCH の必須項目 | 送らなかった場合 |
> |---|---|---|
> | `/teams/:id` | `name`, `members` | HTTP 500 |
> | `/resource_groups/:id` | `name` | エラー |
>
> これらは更新前に detail を GET し、変更しない項目も含めて全量を送ること。
> 詳細は teams.md / resource-groups.md を参照。

ネストオブジェクトも**部分更新**だった（実測）。変えたい項目だけを入れ子で送れば、同じオブジェクト内の
他の項目は保持される。

- データマートの `datamart_bigquery_option`: `write_disposition` だけを送っても、`query`（1 万文字超）・
  `destination_dataset` / `destination_table` / `bigquery_connection_id` は保持された。
- 転送設定の `output_option`: `mode` だけを送っても、出力先データセット / テーブル・接続 ID・
  ロケーションは保持された。
- 転送設定の `input_option`: 1 項目だけを送っても、入力カラム定義（100 件近く）は保持された。

いずれもオブジェクト外の項目（`filter_columns` / `schedules` / `notifications` /
`resource_group_id`）にも影響しなかった。

> [!CAUTION]
> **GET の結果をそのまま PATCH に投げ返すと失敗することがある**。GET レスポンスと PATCH 入力の
> スキーマは一致しない。ワークフローでは実際に、API が自身の GET 出力を 400 で拒否する
> （`tasks[].key` が GET に含まれず、`task_dependencies` が整数で返るため。workflows.md 参照）。
> 複雑な変更は 1 項目ずつ構築し、実行前に必ずユーザーへ差分を提示すること。

## エラーレスポンスの形が一定しない

400 の本文は少なくとも 3 種類ある。どれか 1 つを前提にパースしない。

```json
{"message":"Bad request. Please check your request payload","errors":[{"attribute":"incremental_column","message":"Incremental columnを入力してください。"}]}
{"message":"Tasks keyが必要です, Task dependenciesは無効な 配列 です","errors":[]}
{"error":"タスクの依存関係が不正です"}
```

- `errors[].attribute` があるときは、どの項目が足りないかを特定できる。ユーザーへの報告に使う。
- **404 `Not found` はリソース不在とは限らない**。ワークフローの PATCH では、タスクの `type` と
  `definition_id` の種別が食い違うときにも 404 が返る（対象のワークフローは存在している）。
- 削除済みリソースの GET は 404 ではなく **403 `Not Authorized`** が返ることがある。

## 安全に運用するための共通ルール

1. **読み取りは自由・書き込みは必ず確認**。棚卸し・一覧・診断（GET）は自由に実行してよい。
   PATCH / POST / DELETE などの変更系は、対象一覧と変更内容（before/after）をユーザーに提示し、
   承認を得てから実行する。
2. **ドライラン優先**。まず対象を列挙 → 変更案を提示 → 承認 → 少数で試行 → 全件、の順で進める。
3. **べき等性**。同じ skill を再実行しても二重適用にならないよう、適用前に「すでに設定済みか」を判定する。
4. **レート制限**。下記「レートリミット」を参照。ラッパーが 429 を自動リトライするが、
   大量の detail 取得を行う skill は**事前に必要呼び出し回数を見積もり**、上限に近い場合はユーザーに確認する。
5. **取りこぼしを黙って捨てない**。API 制約で処理できなかった対象（400 の非対応コネクタ、
   機能非対応など）は、**件数と理由を必ず最後に報告**する。分母に混ぜて「対象 N 件」とだけ出さない。

## レートリミット

- **上限**: 10 分あたり: 30 日間トライアル **100 回** / Advanced プラン以上 **3,500 回**（アカウント単位）。
- 超過すると **HTTP 429**。レスポンスヘッダーで残量を確認できる（実測で確認済み）:

| ヘッダー | 内容 |
|---|---|
| `X-Rate-Limit-Limit` | 10 分あたりの上限（100 / 3500） |
| `X-Rate-Limit-Remaining` | 現在のウィンドウの残り回数 |
| `X-Rate-Limit-Reset` | ウィンドウがリセットされる UNIX 時刻 |

- **ラッパー `trocco-api.sh` が 429 を自動リトライする**（`X-Rate-Limit-Reset` まで待機）。
  - `TROCCO_MAX_RETRY`（既定 3）/ `TROCCO_MAX_WAIT`（既定 120 秒）/ `TROCCO_NO_RETRY=1` で調整。
  - 待機が上限を超える場合は中断してエラーを返す。
  - ただし `-o` / `-D` / `-w` を指定した場合は curl に委譲するため**自動リトライは効かない**。
- **呼び出し回数の見積もり**: 一覧は `limit=200` なので「全件 ÷ 200」回。detail 取得は**対象 1 件につき 1 回**。
  例: データマート 600 件の `write_disposition` 判定には約 **603 回**必要。
  トライアル（100 回/10 分）では上限を超えるので、**対象を絞るか分割実行**する。残量の確認:

```bash
trocco-api.sh '/teams?limit=1' -o /dev/null -D - 2>/dev/null | grep -i x-rate-limit
```

## エラーハンドリング

| ステータス | 意味 | 対処 |
|---|---|---|
| 401 | API キー不正 / 未設定 | `$TROCCO_API_KEY` を確認 |
| 403 | 権限不足（Policy 拒否） | 該当リソースへの権限（管理者 / リソースグループ role）を確認 |
| 404 | リソース無し | id / type を確認 |
| 422 | バリデーションエラー | レスポンス `message` を読む。必須項目・enum 値の欠落が多い |
| 429 | レート制限 | バックオフして再試行 |

## 実地検証で判明した重要な挙動（要注意）

以下は数千件規模のアカウントで検証して確認した挙動。skill 実装時は必ず考慮する。

- **`index` に出るが `show`/`update` が非対応のコネクタがある**。転送設定の一覧（index）には全件出るが、
  一部の転送元/先の組み合わせ（例: `custom_connector` ソース等）は詳細取得（`GET /job_definitions/:id`）で
  **HTTP 400 `{"message":"指定された転送元先はまだサポートされていません"}`** を返す。
  **割合はアカウントによって大きく異なり、実測では転送設定サンプルの 2 割前後が該当したケースもある**（数 % で済むとは限らない）。
  → detail を GET する skill は **400 を握って対象からスキップ**し、「非対応で処理できなかった件数」を報告すること。
- **空配列のフィールドはレスポンスからキーごと省略される**。`schedules` / `notifications` などは
  「設定が無い定義では key 自体が存在しない」。判定は `(.schedules // [])` のように**存在しない前提**で書く。
- **スケジュールの ON/OFF（有効/無効）状態は公開 API では取得できない**。`schedules[]` の要素は
  `frequency` / `minute` / `hour` / `day` / `day_of_week` / `time_zone` のみで、**有効/無効フラグを持たない**。
  UI 上で OFF にされたスケジュールも、ON のものと**同じ形**で返る。
  → 「スケジュールがある = 実際に動いている」とは限らない。スケジュールの移設・削除を伴う skill
  （`workflows.md` の集約等）では、**ON/OFF は API から判別不能である旨を明示し、
  対象ごとにユーザーへ確認**すること。

## 公式ドキュメントは URL の末尾に `.md` を付けて取得する

公式ドキュメントは SPA のため、URL をそのまま取得しても中身を読めない。
**末尾に `.md` を付けると Markdown が返る**（実測で確認）。リクエストパラメータや
レスポンススキーマの詳細まで含まれるので、仕様を確認するときは必ずこちらを使う。

```bash
# API リファレンスの目次
curl -sS https://documents.trocco.io/apidocs.md

# 個別エンドポイント（末尾の slug は apidocs のページ URL と同じ）
curl -sS https://documents.trocco.io/apidocs/post-datamart-definition.md
curl -sS https://documents.trocco.io/apidocs/get-job-definitions.md
```

`.md` を付けない URL は人間がブラウザで読む用。エージェントが取得するときは必ず付けること。
機能ドキュメント（`/docs/…`）でも同様に使える。

## 公式ドキュメント

- API リファレンス: https://documents.trocco.io/apidocs.md
- API 総合: https://documents.trocco.io/docs/trocco-api.md
- データマート: https://documents.trocco.io/docs/data-mart.md
- 転送設定: https://documents.trocco.io/docs/etl-configuration.md
- ワークフロー: https://documents.trocco.io/docs/about-workflow.md

ドキュメント全体の索引は https://documents.trocco.io/llms.txt にある
（`/docs/…` 系のみで、API リファレンスは含まれない）。
