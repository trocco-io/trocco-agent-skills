---
name: audit-2fa
description: TROCCO のユーザー一覧を確認し、二段階認証（2FA）が未設定のユーザーを洗い出して棚卸しを支援する。role や最終ログインを加味して是正対象を提示する。「2段階認証の棚卸し」「2FA未設定ユーザーを確認して」と依頼されたときに使う。
---

# 二段階認証（2FA）未設定ユーザーの棚卸し

ユーザー一覧から 2FA 未設定（`otp_required_for_login == false`）を検出し、棚卸しリストを作る。

## 大原則: API はラッパー `trocco-api.sh` 経由で呼ぶ

`curl` で直接叩かない。ベース URL と `Authorization` ヘッダーはラッパーが所有するので、
**パス以降と curl 引数だけ**を渡す（API キーの値を読む必要はない）。

ラッパーの置き場所は導入方法によって変わる。まず次でパスを確定する。

```bash
# ls はエイリアス（-F 等）で表示が変わることがあるため使わない
for p in {.claude,.agents}/skills/audit-2fa/scripts/trocco-api.sh bin/trocco-api.sh; do
  [ -f "$p" ] && echo "$p" && break
done
```

以降この SKILL.md と `references/` に出てくる `trocco-api.sh` は、確定したパスに読み替えて実行する。
コマンドごとにシェルは切り替わるため、変数には入れず毎回フルパスで書く。

```bash
bash .claude/skills/audit-2fa/scripts/trocco-api.sh "/job_definitions?limit=200"   # パスは確定した値に置き換える
```

## 前提知識（必ず先に読む）
- [`knowledge/trocco-api.md`](./references/trocco-api.md)
- [`knowledge/users-2fa.md`](./references/users-2fa.md): **API では 2FA を強制できない（検出のみ）**

## 手順

### 1. ユーザー取得（読み取りのみ）
`GET /users` を全ページ取得し、`otp_required_for_login == false` を抽出する。

### 2. 未ログインと稼働中の切り分け（棚卸しリストより先に行う）
`last_sign_in_at` が null（never）のユーザーは、招待されたまま一度もログインしていないアカウント。
2FA が未設定なのは当然なので、設定を依頼しても意味がない。先に次の 2 群へ分ける。

- **A. 未ログイン（`last_sign_in_at` が null）** … 2FA 依頼ではなく**アカウント棚卸しの対象**。
  `created_at` が古いもの、`teams` が空のものは特に整理候補。
- **B. 稼働中（`last_sign_in_at` あり）で 2FA 未設定** … 本来のセキュリティ是正対象。

> 実アカウントでは 2FA 未設定が全件 A だったケースがある。
> 切り分けずに role 順で並べると、放置された招待を最優先の是正対象として報告してしまう。

### 3. 棚卸しリストの作成
B を主リストとし、email / role / last_sign_in_at の表にする。
role が `super_admin` / `admin` のものを最優先で示す。
A は件数と一覧を別枠で示し、B とは目的が違うことを明記する。

### 4. 推奨アクションの提示
- B: 2FA は API から強制できないため、成果物は「対象者一覧 + 各自で 2FA を設定する依頼文面」まで。
- A: 削除するかどうかはユーザーが判断する。`DELETE /users/:id` で削除できるが、
  **削除は破壊的**。必ず個別に承認を得る。

## 注意
- 出力に email 等の個人情報を含むため、共有範囲に注意する。
- この skill 単体では設定変更を行わない（2FA 強制は不可）。削除を行う場合のみ、明示承認のうえ実行する。
