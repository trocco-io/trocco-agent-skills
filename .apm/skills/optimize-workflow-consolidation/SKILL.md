---
name: optimize-workflow-consolidation
description: 個別にスケジュール実行されている TROCCO の転送設定・データマート定義を洗い出し、ワークフロー（pipeline）へ集約する提案・作成を行う。「個別スケジュールをワークフローにまとめて」と依頼されたときに使う。
---

# 個別スケジュール → ワークフロー集約の提案

個別に `schedules` を持つ転送設定 / データマート定義を検出し、
関連するものをワークフロー（pipeline_definition）へ束ねる提案と作成を支援する。

## 大原則: API はラッパー `trocco-api.sh` 経由で呼ぶ

`curl` で直接叩かない。ベース URL と `Authorization` ヘッダーはラッパーが所有するので、
**パス以降と curl 引数だけ**を渡す（API キーの値を読む必要はない）。

ラッパーの置き場所は導入方法によって変わる。まず次でパスを確定する。

```bash
# ls はエイリアス（-F 等）で表示が変わることがあるため使わない
for p in {.claude,.agents}/skills/optimize-workflow-consolidation/scripts/trocco-api.sh bin/trocco-api.sh; do
  [ -f "$p" ] && echo "$p" && break
done
```

以降この SKILL.md と `references/` に出てくる `trocco-api.sh` は、確定したパスに読み替えて実行する。
コマンドごとにシェルは切り替わるため、変数には入れず毎回フルパスで書く。

```bash
bash .claude/skills/optimize-workflow-consolidation/scripts/trocco-api.sh "/job_definitions?limit=200"   # パスは確定した値に置き換える
```

## 前提知識（必ず先に読む）
- [`knowledge/trocco-api.md`](./references/trocco-api.md)
- [`knowledge/workflows.md`](./references/workflows.md): タスク/依存/スケジュールのスキーマ

## 手順

### 1. 個別スケジュールの洗い出し（読み取りのみ）
`schedules` は **index に含まれる**（実測で確認）ので、一覧取得だけで判定できる（per-id GET は不要）。
`schedules` が 1 件以上あるものを列挙して `frequency` / `time_zone` / 時刻 / 名前 を表にする。

> [!CAUTION]
> 実地検証で判明した注意点（[`knowledge/workflows.md`](./references/workflows.md) / [`trocco-api.md`](./references/trocco-api.md)）:
> - `schedules` は空だと**キーごと省略**される → `(.schedules // [])` で判定。
> - **スケジュールの ON/OFF は API から判別できない**。OFF のものも ON と同じ形で返るため、
>   「schedules がある = 稼働中」とは限らない。意図的に停止中の定義を集約すると再有効化の恐れ。
>   → 候補ごとに「現在 ON か」をユーザーに確認する。
> - 一部コネクタ（例 `custom_connector` ソース）は detail が HTTP 400。対象外として報告する。

### 2. 束ねる候補のグルーピング（提案）
以下の観点でグループ化して提案する:
- 同一 time_zone・近い実行時刻
- データの依存関係（例: 転送 → その出力を使うデータマート）が推測できるもの
- 同じデータセット/テーブル群を扱うもの

> 依存関係は名前や入出力から**推測**にとどめ、実際の順序はユーザーに確認する。

### 3. ワークフロー作成案の提示（ユーザー承認が必須）
- 各定義を `tasks`（`trocco_transfer` / `trocco_bigquery_datamart` 等、`definition_id` で参照）に変換。
- `task_dependencies` で実行順序を表現。
- ワークフローに `schedules` を 1 つ設定（集約後の実行時刻）。
- 通知・リソースグループも引き継ぐか確認。

### 4. 作成と「元スケジュールの停止」
1. `POST /pipeline_definitions` でワークフローを作成。`tasks[].key` は自分で決めた文字列を使い、
   `task_dependencies` もその `key` で結ぶ。
2. 動作確認後、**元の個別 schedule を外す**（各定義に `schedules: []` を PATCH）。
   - これを忘れると二重実行になる。破壊的操作なので必ず確認し、段階的に外す。
3. 作成したワークフロー id と、schedule を外した定義一覧を報告。

> [!CAUTION]
> **既存ワークフローを更新するときは `tasks` と `task_dependencies` を送らない**。
> GET のレスポンスには `tasks[].key` が含まれず、`task_dependencies` は整数で返るため、
> **GET の結果をそのまま PATCH へ渡すと 400 で拒否される**（実測で確認）。
> スケジュールや通知だけを変えるならトップレベルの差分更新で足り、タスク構成は保持される。
> `name` は PATCH の必須項目なので同梱する。
>
> ```bash
> trocco-api.sh -X PATCH -H 'Content-Type: application/json' "/pipeline_definitions/$id" \
>   -d '{ "name": "<現在の名前>", "schedules": [ ... ] }'
> ```
>
> タスク構成そのものを変える場合の手順は
> [`knowledge/workflows.md`](./references/workflows.md)「最大の落とし穴」を参照。

## やってはいけないこと
- 実行順序（依存）を推測のまま確定しない。必ずユーザーに確認。
- ワークフロー作成前に元スケジュールを外さない（未実行期間が生じる）。逆に、外し忘れて二重実行にもしない。
