# リソースグループ（Resource Groups）: API 仕様

> 2026-09-09 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

まず `trocco-api.md` を読むこと。

## モデル

- **リソースグループ** はチーム × 権限（role）の集合。定義（転送/データマート/ワークフロー）を
  グループに属させることで、チーム単位のアクセス制御を行う。
- **定義側が `resource_group_id`（スカラー）を持つ**。所属の付与は定義の PATCH で行う
  （リソースグループ側に定義リストを持たせて管理するのではない）。

### リソースグループスキーマ `/resource_groups`

```
{
  id: integer,
  name: string,
  description: string | null,
  teams: [ { team_id: integer, role: "administrator"|"editor"|"operator"|"viewer" } ],
  created_at, updated_at
}
```

role は 4 種: `administrator` / `editor` / `operator` / `viewer`。

> [!CAUTION]
> **`POST /resource_groups` と `PATCH /resource_groups/:id` はどちらも `name` が必須**。
> リソースグループ自体を更新するときは `description` や `teams` だけを送らず、`name` も同梱する
> （`teams` は配列なので洗い替え。既存の割り当てを残すなら全量を送る）。
>
> 定義側にリソースグループを割り当てる操作（下記）は定義の `resource_group_id` を PATCH するだけなので、
> この制約は関係しない。

```bash
# リソースグループ一覧（id と name の対応表を作る）
trocco-api.sh "/resource_groups?limit=200" | jq -r '.items[] | "\(.id)\t\(.name)"'
```

## 定義への割り当て（すべて `resource_group_id` スカラー）

`resource_group_id` は差分更新できるスカラー項目。**通知や schedule と違い洗い替えの心配はない**。
1 項目だけ PATCH すれば他設定は保持される。

```bash
# 転送設定にリソースグループを割り当て
trocco-api.sh -X PATCH -H 'Content-Type: application/json' \
  "/job_definitions/123" -d '{ "resource_group_id": 45 }'

# データマート定義（update は member action。パスは同じ /:id への PATCH）
trocco-api.sh -X PATCH -H 'Content-Type: application/json' \
  "/datamart_definitions/678" -d '{ "resource_group_id": 45 }'

# ワークフロー定義
trocco-api.sh -X PATCH -H 'Content-Type: application/json' \
  "/pipeline_definitions/90" -d '{ "resource_group_id": 45 }'
```

- 外す場合は `{ "resource_group_id": null }`。

## 「リソースグループが無い定義」の検出

index / show の各定義は `resource_group_id`（integer | null）を返す
（datamart の detail は `resource_group` オブジェクトを返すこともあるので両対応する）。

```bash
# リソースグループ未設定の転送設定
fetch_all job_definitions \
  | jq -r 'select(.resource_group_id == null) | "\(.id)\t\(.name)"'

# データマート（detail は resource_group オブジェクトの場合あり）
fetch_all datamart_definitions \
  | jq -r 'select((.resource_group_id // .resource_group // null) == null) | "\(.id)\t\(.name)"'

# ワークフロー
fetch_all pipeline_definitions \
  | jq -r 'select(.resource_group_id == null) | "\(.id)\t\(.name)"'
```

## 権限に関する注意

- 割り当てには対象定義とリソースグループ双方への権限が必要（無いと 403）。
- リソースグループを付けると、そのグループに属さないチームからは定義が見えなく/操作できなくなる可能性がある。
  **付与を提案する前に、現在アクセスしている運用者/チームが失権しないか**を確認すること。

## 棚卸し: 利用実態が怪しいリソースグループの検出

リソースグループには 2 つの向き先（チーム / 定義）がある。どちらも空なら実質機能していない。

### A. チームが紐づいていないリソースグループ
`teams` が空のリソースグループ。誰にも権限を与えていない。

```bash
fetch_all resource_groups \
  | jq -r 'select((.teams // []) | length == 0) | "\(.id)\t\(.name)"'
```

### B. 定義が 1 つも紐づいていないリソースグループ
転送設定・データマート・ワークフロー定義の `resource_group_id` を全種別から集め、
どの定義からも参照されていないリソースグループを洗い出す。

```bash
TD="${TMPDIR:-/tmp}"
# 使われている resource_group_id 集合を 3 種別から収集
{ fetch_all job_definitions; fetch_all datamart_definitions; fetch_all pipeline_definitions; } \
  | jq -r '(.resource_group_id // .resource_group.id // empty)' | sort -u > "$TD/used_rg_ids.txt"
# 参照されていないリソースグループ
fetch_all resource_groups | jq -r '"\(.id)\t\(.name)"' \
  | while IFS=$'\t' read -r id name; do
      grep -qx "$id" "$TD/used_rg_ids.txt" || printf '%s\t%s\n' "$id" "$name"
    done
```

- A かつ B（チームも定義も無い）は削除候補として最優先で提示する。
- 削除は `DELETE /resource_groups/:id`（破壊的）。必ず個別に承認を得る。
- 詳細な統合フローやチーム側の棚卸しは `teams.md` を参照。
