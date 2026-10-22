# TROCCO API: 基礎知識

> 2026-10-20 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

すべての skill が前提とする、TROCCO API の共通仕様。
skill を実行する前に、まずこのファイルを読むこと。

話題別の知識は別ファイルにある。skill の「前提知識」に挙がっているものだけを読めばよい。

- `trocco-api-update.md`: 更新（PATCH）の挙動（差分更新・配列の洗い替え・ネストの部分更新）とエラーレスポンスの形

リソースとジョブのエンドポイント一覧は、リポジトリの `knowledge/trocco-api-endpoints.md` にある。
skill を設計するときの参照用で、skill には同梱しない（実行中の skill は自分の前提知識に載っているエンドポイントを使う）。

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
  - 公式の上限は 100（`/job_definitions`）だが、`limit=200` でも 200 件返る（実測で確認済み）。
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

> [!IMPORTANT]
> **空配列のフィールドはレスポンスからキーごと省略される**。`schedules` / `notifications` などは
> 「設定が無い定義では key 自体が存在しない」。判定は `(.schedules // [])` のように**存在しない前提**で書く。

## 詳細取得（show）が 400 になるコネクタがある

転送設定の一覧（index）には全件出るが、一部の転送元/先の組み合わせ（例: `custom_connector` ソース等）は
詳細取得（`GET /job_definitions/:id`）や更新で
**HTTP 400 `{"message":"指定された転送元先はまだサポートされていません"}`** を返す。
**割合はアカウントによって大きく異なり、実測では転送設定サンプルの 2 割前後が該当したケースもある**（数 % で済むとは限らない）。
→ detail を GET する skill は **400 を握って対象からスキップ**し、「非対応で処理できなかった件数」を報告すること。

## ジョブの実行ログは API で取得できる

転送・データマート・dbt ジョブの実行ログ（エラーログを含む）は `GET /jobs/:id/logs` / `/datamart_jobs/:id/logs` /
`/dbt_jobs/:id/logs` で取得できる（ワークフロージョブだけは不可）。**「API ではエラー内容を確認できない」と判断しない**。
失敗原因を調べるときは `troubleshoot-job-logs` skill を使う。

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
| 400 | 不正なリクエスト | `message` / `errors[]` を読む。本文の形は一定しない（変更系は trocco-api-update.md「エラーレスポンスの形が一定しない」） |
| 401 | API キー不正 / 未設定（チーム・リソースグループの更新では権限不足も） | `$TROCCO_API_KEY` と権限を確認 |
| 403 | 権限不足（Policy 拒否）。削除済みリソースの GET でも 404 ではなく `Not Authorized` が返ることがある | 該当リソースへの権限（管理者 / リソースグループ role）と、リソースが削除されていないかを確認 |
| 404 | リソース無し | id / type を確認 |
| 422 | バリデーションエラー | レスポンス `message` を読む。必須項目・enum 値の欠落が多い |
| 429 | レート制限 | バックオフして再試行 |
| 503 | 一時的な取得失敗（実行ログ取得 API） | `Retry-After` の秒数だけ待って再試行 |

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
