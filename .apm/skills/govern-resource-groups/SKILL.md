---
name: govern-resource-groups
description: リソースグループが未設定の TROCCO の転送設定・データマート定義・ワークフロー定義を洗い出し、ユーザーが指定したリソースグループを割り当てる。「リソースグループが無い定義に付けて」「リソースグループの棚卸し」と依頼されたときに使う。
---

# リソースグループが無い定義に割り当てる

リソースグループ（`resource_group_id`）が未設定の定義を検出し、ユーザーが選んだグループを割り当てる。

## 大原則: API はラッパー `trocco-api.sh` 経由で呼ぶ

`curl` で直接叩かない。ベース URL と `Authorization` ヘッダーはラッパーが所有するので、
**パス以降と curl 引数だけ**を渡す（API キーの値を読む必要はない）。

ラッパーの置き場所は導入方法によって変わる。まず次でパスを確定する。

```bash
# ls はエイリアス（-F 等）で表示が変わることがあるため使わない
for p in {.claude,.agents}/skills/govern-resource-groups/scripts/trocco-api.sh bin/trocco-api.sh; do
  [ -f "$p" ] && echo "$p" && break
done
```

以降この SKILL.md と `references/` に出てくる `trocco-api.sh` は、確定したパスに読み替えて実行する。
コマンドごとにシェルは切り替わるため、変数には入れず毎回フルパスで書く。

```bash
bash .claude/skills/govern-resource-groups/scripts/trocco-api.sh "/job_definitions?limit=200"   # パスは確定した値に置き換える
```

## 前提知識（必ず先に読む）
- [`knowledge/trocco-api.md`](./references/trocco-api.md)
- [`knowledge/resource-groups.md`](./references/resource-groups.md)

## 手順

### 1. 対象の洗い出し（読み取りのみ）
対象種別を確認し、`resource_group_id == null`（datamart detail は `resource_group` オブジェクト）の定義を列挙。

```bash
# リソースグループ一覧（id/name の対応表）
trocco-api.sh "/resource_groups?limit=200" | jq -r '.items[] | "\(.id)\t\(.name)"'
```

「リソースグループ未設定: N 件」の一覧を提示する。

### 2. 割り当て先の確認（ユーザー承認が必須）
- どのリソースグループを割り当てるか（一律 or 定義ごと）。
- **失権チェック**: そのグループに属さないチーム/運用者が対象定義を操作できなくなる恐れがある。
  現在の運用者が失権しないかを確認してから進める。

### 3. 適用（スカラーなので安全）
`resource_group_id` はスカラーの差分更新。1 項目だけ PATCH すれば他設定は保持される。

```bash
trocco-api.sh -X PATCH -H 'Content-Type: application/json' \
  "/job_definitions/<id>" -d '{ "resource_group_id": <rg_id> }'
```

- すでに設定済みの定義はスキップ（べき等）。
- まず 1 件で確認 → 横展開。変更した id 一覧と before/after を報告。

## やってはいけないこと
- ユーザー承認なしに割り当てない。
- 失権リスクの確認を飛ばさない。
