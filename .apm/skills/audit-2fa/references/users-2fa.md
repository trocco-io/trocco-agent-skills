# ユーザーと二段階認証（2FA）: API 仕様

> 2026-09-09 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

二段階認証が未設定のユーザーを棚卸しするための知識。
まず `trocco-api.md` を読むこと。

## ユーザースキーマ `/users`

| フィールド | 型 / enum | 備考 |
|---|---|---|
| `id` | integer | |
| `email` | string | |
| `role` | `super_admin` \| `admin` \| `member` | |
| `otp_required_for_login` | boolean | **二段階認証（TOTP）の設定有無** |
| `can_use_basic_services` | boolean | |
| `can_use_data_catalog` | boolean | |
| `can_use_audit_log` | boolean | アカウントが監査ログ機能を持たない場合は無いことがある |
| `is_restricted_connection_modify` | boolean | |
| `teams` | `[{ id, name, role(team_member\|team_admin) }]` | |
| `last_sign_in_at` | string(date-time) \| null | 最終ログイン |
| `created_at` / `updated_at` | string(date-time) | |

## 2FA は「検出のみ」: API では変更不可

- **読み取り**: `GET /users` / `GET /users/:id` で `otp_required_for_login` を確認できる。
  - `true` = 2FA 有効 / `false` = 2FA 未設定
- **書き込み**: `otp_required_for_login` は POST/PATCH の入力に**含まれない**。
  API から 2FA を強制 ON / OFF することは**できない**（各ユーザーが管理画面で設定する）。

→ この skill でできるのは「2FA 未設定ユーザーの検出・棚卸しリスト作成・是正の促し」まで。強制適用は不可。

## 2FA 未設定ユーザーの検出

```bash
fetch_all users | jq -r '
  select(.otp_required_for_login == false)
  | "\(.id)\t\(.email)\t\(.role)\t\(.last_sign_in_at // "never")"'
```

## 棚卸しの観点

- **`last_sign_in_at` が null（never）のユーザーを先に切り分ける**。一度もログインしていない以上、
  2FA が未設定なのは当然で、設定を依頼する相手ではない。招待の放置として
  **アカウント棚卸し**（`DELETE /users/:id` の検討）に回す。`teams` が空、`created_at` が古い、
  といった条件を併せて見ると判断しやすい。
- 残った「ログイン実績があるのに 2FA 未設定」が本来の是正対象。そのうち **role が高いユーザー**
  （super_admin / admin）を優先する。
- API で 2FA を強制できないため、成果物は
  「対象者一覧 + 推奨アクション（各自で 2FA 設定 / 未ログインなら削除）」となる。
- メールアドレス等の個人情報を扱うので、出力の取り扱い（共有範囲）に注意する。

## 参考: ユーザーの作成 / 更新 / 削除で操作できる項目

- 作成 `POST /users`: `email`(必須), `password` / `password_auto_generated`, `role`(admin|member),
  `can_use_audit_log`, `is_restricted_connection_modify`
- 更新 `PATCH /users/:id`: `role`, `can_use_audit_log`, `is_restricted_connection_modify`
- 削除 `DELETE /users/:id`
- いずれも `otp_required_for_login` は操作対象外。
