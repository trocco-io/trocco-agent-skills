---
name: audit-stale-resource-groups
description: 利用実態が怪しい TROCCO のリソースグループの棚卸しを支援する。チームが紐づいていない、または転送設定・データマート・ワークフロー定義が 1 つも紐づいていないリソースグループを検出する。「リソースグループの棚卸し」「使われていないリソースグループを整理して」と依頼されたときに使う。
---

# 利用実態が怪しいリソースグループの棚卸し

チームにも定義にも紐づいていないリソースグループを洗い出し、整理（削除）を支援する。

## 大原則: API はラッパー `trocco-api.sh` 経由で呼ぶ

`curl` で直接叩かない。ベース URL と `Authorization` ヘッダーはラッパーが所有するので、
**パス以降と curl 引数だけ**を渡す（API キーの値を読む必要はない）。

ラッパーの置き場所は導入方法によって変わる。まず次でパスを確定する。

```bash
# ls はエイリアス（-F 等）で表示が変わることがあるため使わない
for p in {.claude,.agents}/skills/audit-stale-resource-groups/scripts/trocco-api.sh bin/trocco-api.sh; do
  [ -f "$p" ] && echo "$p" && break
done
```

以降この SKILL.md と `references/` に出てくる `trocco-api.sh` は、確定したパスに読み替えて実行する。
コマンドごとにシェルは切り替わるため、変数には入れず毎回フルパスで書く。

```bash
bash .claude/skills/audit-stale-resource-groups/scripts/trocco-api.sh "/job_definitions?limit=200"   # パスは確定した値に置き換える
```

## 前提知識（必ず先に読む）
- [`knowledge/trocco-api.md`](./references/trocco-api.md)
- [`knowledge/resource-groups.md`](./references/resource-groups.md): 「棚卸し」節（A: チーム無し / B: 定義無し）
- 関連: [`knowledge/teams.md`](./references/teams.md)

## 手順

### 1. データ収集（読み取りのみ）
`GET /resource_groups` と、全種別の定義（`job_definitions` / `datamart_definitions` /
`pipeline_definitions`）を全ページ取得する。

### 2. 候補の検出
- **A. チーム未設定**: リソースグループの `teams` が空（誰にも権限を与えていない）。
- **B. 定義未参照**: どの定義の `resource_group_id` からも参照されていない。
- **A かつ B**（チームも定義も無い）を最優先の削除候補として分類。

### 3. 棚卸しリストの提示
各候補に id / name / teams 数 / 参照定義数 / 分類を付けて提示する。

### 4. 削除（破壊的操作は個別承認）
- 削除は `DELETE /resource_groups/:id`。
- 定義が紐づいている場合は削除前に付け替え/外しの方針をユーザーに確認（[`resource-groups.md`](./references/resource-groups.md)）。
- 1 件ずつ確認しながら実施し、結果を報告。

## やってはいけないこと
- 定義やチームが紐づくリソースグループを、影響確認なしに削除しない。
- 検出だけで削除の即時実行を促さない。必ず一覧提示 → 承認 → 段階削除。
