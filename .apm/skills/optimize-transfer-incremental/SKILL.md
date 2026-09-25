---
name: optimize-transfer-incremental
description: 全件洗い替えの TROCCO 転送設定を差分転送（増分取得＋merge書き込み）へ切り替える。適否を判定し、転送元の増分取得と転送先のmergeモードを設定する。「洗い替えの転送を差分転送にして」と依頼されたときに使う。
---

# 洗い替え転送 → 差分転送への切り替え

転送先が全件洗い替え（`replace` / `truncate_insert`）の転送設定を、
差分転送（転送元の増分取得 + 転送先の `merge`）へ切り替える。

## 大原則: API はラッパー `trocco-api.sh` 経由で呼ぶ

`curl` で直接叩かない。ベース URL と `Authorization` ヘッダーはラッパーが所有するので、
**パス以降と curl 引数だけ**を渡す（API キーの値を読む必要はない）。

ラッパーの置き場所は導入方法によって変わる。まず次でパスを確定する。

```bash
# ls はエイリアス（-F 等）で表示が変わることがあるため使わない
for p in {.claude,.agents}/skills/optimize-transfer-incremental/scripts/trocco-api.sh bin/trocco-api.sh; do
  [ -f "$p" ] && echo "$p" && break
done
```

以降この SKILL.md と `references/` に出てくる `trocco-api.sh` は、確定したパスに読み替えて実行する。
コマンドごとにシェルは切り替わるため、変数には入れず毎回フルパスで書く。

```bash
bash .claude/skills/optimize-transfer-incremental/scripts/trocco-api.sh "/job_definitions?limit=200"   # パスは確定した値に置き換える
```

## 前提知識（必ず先に読む）
- [`knowledge/trocco-api.md`](./references/trocco-api.md)
- [`knowledge/incremental-transfer.md`](./references/incremental-transfer.md)
- 適否判定は [`knowledge/datamart-write-modes.md`](./references/datamart-write-modes.md) の「切り替え不可の 5 パターン」を流用

## 手順

### 1. 候補の洗い出し（読み取りのみ）
転送先 mode が `replace` / `truncate_insert` の転送設定を列挙。
転送元コネクタが増分取得に対応しているか（MySQL/PostgreSQL/MongoDB/S3/GCS/SFTP/GA4/HubSpot 等）も確認。

> [!NOTE]
> **レートリミットに注意**（10 分あたり トライアル 100 回 / Advanced 以上 3,500 回）。
> この skill は対象 1 件につき detail を 1 回取得するため、対象が多いと上限に近づく。
> **実行前に必要回数を見積もり**（一覧 ≒ 全件÷200 回 ＋ detail ≒ 対象件数）、
> 上限に対して大きい場合は対象を絞るかユーザーに確認する。
> ラッパーは 429 を自動リトライする。残量確認:
> `trocco-api.sh '/teams?limit=1' -o /dev/null -D - 2>/dev/null | grep -i x-rate-limit`

### 1.5 3 分類して集計する（取りこぼし防止）
`incremental_loading_enabled` は **非対応コネクタでは `null`（キー無し）** になる。
`== false` だけで絞ると洗い替えの定義が黙って消えるため、必ず 3 分類する:

| 分類 | 条件 | 扱い |
|---|---|---|
| 候補 | `== false` かつ mode が `replace`/`truncate_insert` | 適否判定へ |
| 対応済み | `== true` | 対象外 |
| **非対応コネクタ** | `== null` | **件数を明示報告** |

また detail GET が **HTTP 400（非対応の転送元/先）** になるものがある（実測で 1〜2 割に達することも）。
400 はスキップし、件数を報告する。

### 実行結果の報告フォーマット（必須）

処理できなかった対象を黙って捨てない。最後に必ず次を出す:

```
対象: N 件 / 候補: M 件
未処理: K 件
  - 非対応コネクタ（detail が HTTP 400）: a 件
  - 機能非対応（対象外）: b 件
```

### 2. 適否判定（1 件ずつ）
差分転送に向かないケース（レコードが消える / 一意キーが無い / 集計・JOIN が遡って変わる）に
該当しないかをユーザーと確認。該当すれば洗い替え維持を推奨し理由を提示。

### 3. 変更案の提示（ユーザー承認が必須）
- 転送元: `incremental_loading_enabled: true`、`table`、`incremental_columns`（増分カラム）を設定、`query` は外す。
- 転送先: `mode: "merge"`、merge キー配列を設定。
- before/after を必ず提示。

### 4. 適用と検証
> `input_option` / `output_option` は**部分更新できる**（実測で確認）。**変える項目だけを入れ子で送る**こと。
> オブジェクト全体を組み立て直す必要はなく、そのほうが取りこぼしの危険も小さい。
> まず 1 件 PATCH → テスト実行で件数・整合性を検証 → 横展開。

```jsonc
// 例は knowledge/incremental-transfer.md 参照（MySQL → BigQuery merge）
```

初回は `last_record: null` で全件取り込み、以降は増分のみ。

## やってはいけないこと
- 適否判定を飛ばして一括変換しない（データ欠落・不整合の原因）。
- 検証（再実行で件数一致）を省略しない。
