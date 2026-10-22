---
name: troubleshoot-failed-jobs
description: 期間や転送設定・ワークフローを指定して TROCCO の転送ジョブの実行結果を取得し、失敗したジョブを洗い出して失敗の出方（作成以来未成功・ある時点から毎回・散発）を分類する。原因調査は troubleshoot-job-logs に引き継ぐ。「最近失敗しているジョブを探して」「この 1 週間のエラーを洗い出して」と依頼されたときに使う。
argument-hint: "[期間（例: 3d）] [定義 ID / 名前 / ワークフロー ID]"
---

# 失敗したジョブを探す

期間と対象の定義を決めて転送ジョブの実行結果を取得し、失敗しているジョブを定義ごとにまとめる。
読み取りのみ。見つけたジョブの原因調査は `troubleshoot-job-logs` で行う。

## 大原則: API はラッパー `trocco-api.sh` 経由で呼ぶ

`curl` で直接叩かない。ベース URL と `Authorization` ヘッダーはラッパーが所有するので、
**パス以降と curl 引数だけ**を渡す（API キーの値を読む必要はない）。

ラッパーの置き場所は導入方法によって変わる。まず次でパスを確定する。

```bash
# ls はエイリアス（-F 等）で表示が変わることがあるため使わない
for p in {.claude,.agents}/skills/troubleshoot-failed-jobs/scripts/trocco-api.sh bin/trocco-api.sh; do
  [ -f "$p" ] && echo "$p" && break
done
```

以降この SKILL.md と `references/` に出てくる `trocco-api.sh` は、確定したパスに読み替えて実行する。
コマンドごとにシェルは切り替わるため、変数には入れず毎回フルパスで書く。

## 前提知識（必ず先に読む）
- [`knowledge/trocco-api.md`](./references/trocco-api.md)
- [`knowledge/job-search.md`](./references/job-search.md): **一覧できるのは転送ジョブだけ、定義 1 件につき 1 回、1 回 100 件まで・新しい順、失敗の出方の分類**

## 手順

### 1. 期間と対象を決める

- 期間: 指定が無ければ**直近 3 日**から始める（ジョブの作成日時で絞る）。広げるのは結果を見てから。
- 対象: ユーザーの指定（定義 ID・名前・ワークフロー・ラベル・リソースグループ）を優先する。
  指定が無ければ、絞り方の候補と件数を示して選んでもらう（`job-search.md`「対象の定義の絞り方」）。
- **データマート・dbt・ワークフローのジョブは一覧できない**ことを最初に伝える。それらの失敗はジョブ URL を貰って
  `troubleshoot-job-logs` で調べる。ワークフローを指定された場合は、配下の転送設定を対象にする。

### 2. 対象の定義を列挙し、呼び出し回数を見積もる

定義一覧を全ページ取得し（`trocco-api.md`「ページネーション」）、ファイルに保存して絞り込む。

```bash
out="${TMPDIR:-/tmp}/trocco_failed_jobs"; mkdir -p "$out/jobs"
# fetch_all job_definitions | jq -s '.' > "$out/job_definitions.json" で全件を保存したうえで:
jq -r '.[] | select(<絞り込み条件>) | .id' "$out/job_definitions.json" | sort -un > "$out/target_ids.txt"
wc -l < "$out/target_ids.txt"
```

- 見積もり = 対象の定義数（+ 期間内に 100 件を超える定義のページ数）。数分おきに動く定義は 1 件で数十回になりうる。
- 残量を確認し（`trocco-api.md`「レートリミット」）、**見積もりが数百回を超える、または残量に近い**ときは、
  件数と見積もりを示して進めてよいか確認する。

### 3. ジョブの実行結果を取得する

```bash
# 日時は URL エンコードする（空白は %20）
st='2026-10-17%2000:00:00'; et='2026-10-20%2023:59:59'
while read -r id; do
  cursor=""; : > "$out/jobs/$id.jsonl"
  while : ; do
    q="/job_definitions/$id/jobs?limit=100&start_time=$st&end_time=$et&time_zone=Asia/Tokyo"
    [ -n "$cursor" ] && q="$q&cursor=$cursor"
    bash <ラッパー> "$q" > "$out/page.json" || { echo "NG $id" >> "$out/failed_fetch.txt"; break; }
    jq -c '.items[]?' "$out/page.json" >> "$out/jobs/$id.jsonl"
    cursor=$(jq -r '.next_cursor // empty' "$out/page.json")
    [ -z "$cursor" ] && break
  done
done < "$out/target_ids.txt"
```

- **`next_cursor` を必ず辿る**。新しい順に返るため、辿らないと期間の前半を取りこぼす。
- 取得に失敗した定義は記録し、最後に件数と理由を報告する（黙って捨てない）。

### 4. 定義ごとに集計し、失敗の出方を分類する

```bash
for f in "$out"/jobs/*.jsonl; do
  id=$(basename "$f" .jsonl)
  jq -s --arg id "$id" 'sort_by(.created_at) | {
      id: ($id|tonumber), total: length,
      failed: map(select(.status=="error" or .status=="timeout")) | length,
      canceled: map(select(.status=="canceled")) | length,
      latest_failed: (map(select(.status=="error" or .status=="timeout")) | last),
      first_failed: (map(select(.status=="error" or .status=="timeout")) | first | .created_at),
      last_succeeded: (map(select(.status=="succeeded")) | last | .created_at),
      latest_status: (last | .status), executor_types: (map(.executor_type) | unique)
    } | select(.failed > 0)' "$f"
done | jq -s 'sort_by(-.failed)' > "$out/summary.json"
```

`job-search.md`「失敗の出方を分類する」に従って分類する。

- 期間内がすべて失敗の定義は、**期間を広げて最初の失敗と最後の成功を探す**。定義の `created_at` より前に遡る必要は無い。
  `created_at` 以降に成功が無ければ「作成以来一度も成功していない」。
- 失敗し始めた時刻と定義の `updated_at` を並べる（直前に更新されていれば、その変更が原因の候補）。

### 5. 報告する

`job-search.md`「報告の形」に従い、定義ごとに 1 行、調べる優先順（作成以来未成功・ある時点から毎回 → 散発 → 回復済み）に並べる。
最新の失敗ジョブは `https://trocco.io/jobs/<id>` の形で示す。

あわせて必ず書く:
- 期間、調べた定義数、呼び出し回数
- 一覧できなかったもの（データマート・dbt・ワークフロー、対象外にした定義、取得に失敗した定義）

### 6. 原因調査へ引き継ぐ

どのジョブを調べるかをユーザーに確認し、`troubleshoot-job-logs` で 1 件ずつ調べる（最新の失敗ジョブを使う）。
件数が多いときは、出方ごとに代表を 1 件ずつ選ぶと、同じ原因をまとめて扱える。

## 注意

- この skill は読み取りのみ。再実行や設定変更はしない。
- 定義一覧には作成者のメールアドレスが含まれる。報告に出すときは共有範囲に注意する。
- 調査が終わったら、保存したファイル（`$out`）を削除してよいかユーザーに確認する。
