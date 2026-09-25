---
name: govern-notifications
description: 通知が設定されていない TROCCO の転送設定・データマート定義・ワークフロー定義を洗い出し、ユーザーが指定した通知を付与する。「通知が無い定義に通知をつけて」「通知の棚卸し」と依頼されたときに使う。
---

# 通知が無い定義に通知を付与する

TROCCO の転送設定 / データマート定義 / ワークフロー定義のうち、通知が未設定のものを検出し、
ユーザーが選んだ通知を付与する運用支援 skill。

## 大原則: API はラッパー `trocco-api.sh` 経由で呼ぶ

`curl` で直接叩かない。ベース URL と `Authorization` ヘッダーはラッパーが所有するので、
**パス以降と curl 引数だけ**を渡す（API キーの値を読む必要はない）。

ラッパーの置き場所は導入方法によって変わる。まず次でパスを確定する。

```bash
# ls はエイリアス（-F 等）で表示が変わることがあるため使わない
for p in {.claude,.agents}/skills/govern-notifications/scripts/trocco-api.sh bin/trocco-api.sh; do
  [ -f "$p" ] && echo "$p" && break
done
```

以降この SKILL.md と `references/` に出てくる `trocco-api.sh` は、確定したパスに読み替えて実行する。
コマンドごとにシェルは切り替わるため、変数には入れず毎回フルパスで書く。

```bash
bash .claude/skills/govern-notifications/scripts/trocco-api.sh "/job_definitions?limit=200"   # パスは確定した値に置き換える
```

## 前提知識（必ず先に読む）
- [`knowledge/trocco-api.md`](./references/trocco-api.md): 認証・ページネーション・「配列は洗い替え」
- [`knowledge/notifications.md`](./references/notifications.md): 通知先 / 通知のスキーマ（3 種で構造が違う）

## 手順

### 1. 対象の洗い出し（読み取りのみ）
対象種別（転送 / データマート / ワークフロー、または全部）をユーザーに確認する。
各定義を取得し、`notifications` が空 / null のものを列挙する。

```bash
# notifications は index に含まれるので per-id GET は不要。
# 通知が無い定義ではキーごと省略されるため (.notifications // []) で判定する。
fetch_all job_definitions \
  | jq -r 'select((.notifications // []) | length == 0) | "\(.id)\t\(.name)"'
```

> `fetch_all` の定義と、**レスポンスは必ずファイル経由で jq に渡す**注意点は
> [`./references/trocco-api.md`](./references/trocco-api.md) を参照。

結果を「通知なし: N 件」の一覧（id, name, 種別）としてユーザーに提示。

### 2. 付ける通知の確認（ユーザー承認が必須）
以下をユーザーに確認する:
- 通知先（既存の Slack / Email 通知先を `GET /notification_destinations/:type` で一覧提示し、選んでもらう）
- 通知条件（失敗時 `failed` / 完了時 `finished` / 実行時間アラート など）
- 一律付与か、定義ごとに変えるか

> [!IMPORTANT]
> **通知先は API では作成できない**（`POST /notification_destinations/:type` は 400 を返す）。
> 使いたい通知先が一覧に無い場合は、TROCCO の画面で作成してもらってから再実行する。

> 種別で通知スキーマが違う点に注意（転送/データマートは `slack_channel_id`/`email_id` + `notification_type`、
> ワークフローは `type` + `slack_config.notification_id`）。
> 転送設定では `message` が**必須**で、実行時間アラートの値は `time` ではなく `exec_time`。

### 3. べき等・非破壊な適用
`notifications` は PATCH で**洗い替え**なので、既存通知を消さないよう:
1. 対象定義を GET し既存 `notifications` を取得
2. 付けたい通知が**すでに含まれていないか**判定（重複付与を避ける）
3. 既存 + 追加分を合わせた**全量**を PATCH

### 4. 段階適用
- まず 1 件に適用して結果を確認 → 問題なければ残りへ。
- 変更した id の一覧と before/after を最後に報告する。

## やってはいけないこと
- ユーザー承認なしに PATCH しない。
- 既存 `notifications` を無視した上書き（洗い替え）で既存通知を消さない。
