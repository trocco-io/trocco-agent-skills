# チーム（Teams）と棚卸し: API 仕様

> 2026-09-09 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

利用実態の薄いチームの棚卸し・統合を支援するための知識。
まず [`trocco-api.md`](./trocco-api.md)、関連して [`resource-groups.md`](./resource-groups.md) を読むこと。

## チームスキーマ `/teams`

```
{
  id: integer,
  name: string,
  description: string | null,
  members: [ { user_id: integer, email: string, role: "team_admin"|"team_member" } ],  // 最低 1 名
  created_at, updated_at
}
```

- `members` は必須（最低 1 名）。所属ユーザーが `email` 付きで得られる。
- 作成 `POST /teams` / 更新 `PATCH /teams/:id` / 削除 `DELETE /teams/:id`。
- **更新時 `members` は洗い替え**: 既存ユーザーを残したい場合は既存 id も含めて全量を送る。

> [!CAUTION]
> **`POST /teams` と `PATCH /teams/:id` はどちらも `name` と `members` が必須**。
> チームは転送設定などと違い、スカラー項目だけの差分更新ができない。
> `description` だけを送ると **HTTP 500** が返る（実測で確認）。
>
> 更新時は `GET /teams/:id` で現在の `name` と `members` を取得し、変えない項目も含めて全量を送る。
>
> ```bash
> # description だけを変えたい場合も、name と members を同梱する
> trocco-api.sh "/teams/$id" > "$TD/team.json"
> jq '{name, description: "新しい説明", members: [.members[] | {user_id, role}]}' "$TD/team.json" \
>   > "$TD/payload.json"
> trocco-api.sh -X PATCH -H 'Content-Type: application/json' "/teams/$id" -d @"$TD/payload.json"
> ```

> [!IMPORTANT]
> **`members` は一覧（`GET /teams`）のレスポンスには含まれない**（実測で確認）。index が返すのは
> `id` / `name` / `description` / `created_at` / `updated_at` のみ。
> メンバー構成を見るには **チームごとに `GET /teams/:id`（detail）を叩く必要がある**（チーム数だけ fan-out する）。

## チームとリソースグループの関係

- リソースグループが `teams: [{ team_id, role }]` を持つ（[`resource-groups.md`](./resource-groups.md)）。
- つまり **「チームがどのリソースグループから参照されているか」は、全リソースグループを走査して
  `teams[].team_id` を集めることで判定する**（チーム側には逆参照が無い）。

## 棚卸しの観点（利用実態が薄いチーム）

### A. どのリソースグループにも紐づいていない stale なチーム
全チーム id から、全リソースグループの `teams[].team_id` の集合を引く。差分が「未参照チーム」。

```bash
TD="${TMPDIR:-/tmp}"
fetch_all teams           | jq -s '.' > "$TD/teams.json"
fetch_all resource_groups | jq -s '.' > "$TD/rgs.json"

# リソースグループから参照されている team_id 集合
jq -r '[.[].teams[]?.team_id] | unique' "$TD/rgs.json" > "$TD/rg_team_ids.json"
# どのリソースグループにも属さないチーム
jq --slurpfile used "$TD/rg_team_ids.json" \
   -r '[.[] | select(.id as $id | ($used[0] | index($id)) | not)] | .[] | "\(.id)\t\(.name)"' \
   "$TD/teams.json"
```

未参照 = そのチームに権限を与えている場所が無い → 実質機能していない可能性。

### B. メンバー構成が同一 / ほぼ同一のチーム（統合候補）
`members[].user_id` の集合をチーム間で比較する。

- **完全一致**: 同じユーザー集合を持つチームは統合候補。
- **ほぼ一致**: Jaccard 係数（積集合 / 和集合）が高い（例 ≥ 0.8）ペアを提示。

> `members` は index に含まれないため、**まずチームごとに detail を取得**してから比較する。

```bash
TD="${TMPDIR:-/tmp}"
# 1) 全チームの detail を取得（members はここでしか取れない）
jq -r '.[].id' "$TD/teams.json" | while read -r id; do
  trocco-api.sh "/teams/$id" > "$TD/team_$id.json"
done
# 2) 各チームの user_id ソート済み集合を作り、完全一致でグルーピング
for f in "$TD"/team_*.json; do
  jq -r '"\(.id)\t\(.name)\t\([.members[]?.user_id]|sort|@json)"' "$f"
done | sort -t$'\t' -k3
# → 3 列目（メンバー集合）が同じ行同士が完全一致の統合候補
```

## 統合・削除の進め方（破壊的操作は要確認）

1. 上記 A/B で候補一覧を作り、ユーザーに提示（id, name, members, 参照リソースグループ）。
2. 統合する場合:
   - 残すチームに `members` を（両チームの和集合で）洗い替え PATCH。
   - 参照しているリソースグループがあれば、`teams` を残すチームへ付け替え（[`resource-groups.md`](./resource-groups.md)）。
   - 不要チームを `DELETE /teams/:id`。
3. **削除前に必ず**: そのチームがリソースグループから参照されていないこと、参照経由でアクセスしている
   運用者が失権しないことを確認する。
4. まず 1 件ずつ・確認しながら実施。email 等の個人情報の取り扱いに注意。
