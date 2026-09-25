---
name: audit-stale-teams
description: 利用実態が薄い TROCCO のチームの棚卸し・統合を支援する。どのリソースグループにも紐づかない stale なチームや、メンバー構成が同一/ほぼ同一で統合候補のチームを検出する。「チームの棚卸し」「使われていないチームを整理して」と依頼されたときに使う。
---

# 利用実態が薄いチームの棚卸し・統合支援

TROCCO のチームのうち、機能していない/重複していると疑わしいものを洗い出し、統合・削除を支援する。

## 大原則: API はラッパー `trocco-api.sh` 経由で呼ぶ

`curl` で直接叩かない。ベース URL と `Authorization` ヘッダーはラッパーが所有するので、
**パス以降と curl 引数だけ**を渡す（API キーの値を読む必要はない）。

ラッパーの置き場所は導入方法によって変わる。まず次でパスを確定する。

```bash
# ls はエイリアス（-F 等）で表示が変わることがあるため使わない
for p in {.claude,.agents}/skills/audit-stale-teams/scripts/trocco-api.sh bin/trocco-api.sh; do
  [ -f "$p" ] && echo "$p" && break
done
```

以降この SKILL.md と `references/` に出てくる `trocco-api.sh` は、確定したパスに読み替えて実行する。
コマンドごとにシェルは切り替わるため、変数には入れず毎回フルパスで書く。

```bash
bash .claude/skills/audit-stale-teams/scripts/trocco-api.sh "/job_definitions?limit=200"   # パスは確定した値に置き換える
```

## 前提知識（必ず先に読む）
- [`knowledge/trocco-api.md`](./references/trocco-api.md)
- [`knowledge/teams.md`](./references/teams.md): 検出ロジック（A: 未参照 / B: メンバー重複）と統合手順
- [`knowledge/resource-groups.md`](./references/resource-groups.md): チーム↔リソースグループの関係

## 手順

### 1. データ収集（読み取りのみ）
`GET /teams` と `GET /resource_groups` を全ページ取得する。

> [!NOTE]
> **レートリミットに注意**（10 分あたり トライアル 100 回 / Advanced 以上 3,500 回）。
> この skill は対象 1 件につき detail を 1 回取得するため、対象が多いと上限に近づく。
> **実行前に必要回数を見積もり**（一覧 ≒ 全件÷200 回 ＋ detail ≒ 対象件数）、
> 上限に対して大きい場合は対象を絞るかユーザーに確認する。
> ラッパーは 429 を自動リトライする。残量確認:
> `trocco-api.sh '/teams?limit=1' -o /dev/null -D - 2>/dev/null | grep -i x-rate-limit`

### 2. 候補の検出
- **A. どのリソースグループにも紐づかない stale チーム**: 全チーム id から、
  全リソースグループの `teams[].team_id` 集合を引いた差分。
- **B. メンバー構成が同一 / ほぼ同一**: `members[].user_id` の集合をチーム間で比較し、
  完全一致・高 Jaccard（例 ≥ 0.8）のペアを統合候補として提示。

### 3. 棚卸しリストの提示
各候補に id / name / members / 参照リソースグループ / 分類（stale か 重複か）を付けて提示。

### 4. 統合・削除（破壊的操作は個別承認）
- 統合: 残すチームに members を和集合で洗い替え PATCH → 参照リソースグループを付け替え →
  不要チームを `DELETE /teams/:id`。
  - **`PATCH /teams/:id` は `name` と `members` が必須**。変えない項目も含めて全量を送る
    （`description` だけを送ると HTTP 500）。詳細は [`./references/teams.md`](./references/teams.md)。
- **削除前チェック**: リソースグループからの参照が無いこと、参照経由の運用者が失権しないこと。
- 1 件ずつ確認しながら実施し、変更内容を報告。

## やってはいけないこと
- 参照や失権の確認をせずにチームを削除しない。
- `members` 洗い替えで残すべきユーザーを落とさない（既存 id を含める）。
- email 等の個人情報の取り扱い（共有範囲）に注意。
