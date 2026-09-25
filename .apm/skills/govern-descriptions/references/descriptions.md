# 説明文（メモ / description）の付与: API 仕様

> 2026-09-09 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

説明が無い / 簡素な定義に、処理内容の説明文を付けるための知識。
まず `trocco-api.md` を読むこと。

## `description` フィールド（3 種すべて書き込み可・スカラー）

| 定義 | フィールド | ラベル | 更新 |
|---|---|---|---|
| 転送設定 | `description` | 転送設定メモ | PATCH で差分更新可（スカラー） |
| データマート定義 | `description`（nullable） | メモ | PATCH で差分更新可 |
| ワークフロー定義 | `description` | ワークフロー詳細（メモ） | PATCH で差分更新可 |

スカラーなので **`description` だけを PATCH すれば他設定は保持される**（洗い替えの心配なし）。

```bash
trocco-api.sh -X PATCH -H 'Content-Type: application/json' \
  "/job_definitions/123" -d '{ "description": "..." }'
```

## 「説明が無い / 簡素」の検出

`description` が null / 空 / 極端に短い（例 20 文字未満）ものを候補とする。

```bash
fetch_all job_definitions | jq -r '
  select((.description // "") | gsub("\\s";"") | length < 20)
  | "\(.id)\t\(.name)\t\((.description // ""))"'
```

閾値（何文字未満を「簡素」とするか）はユーザーに確認する。

## 処理内容から説明文を生成する材料

説明文は **その定義を GET して得られる実際の処理内容**から組み立てる。憶測で書かない。

### 転送設定（job_definition）
- 転送元コネクタ種別・テーブル / クエリ（input_option）
- 転送先コネクタ種別・データセット / テーブル・書き込み mode（output_option）
- フィルタ（`filter_columns`, `filter_rows`, マスキング等）の有無
- 差分転送 / 洗い替えの別、スケジュール

→ 例:「MySQL `prod.orders` を BigQuery `analytics.orders` へ日次で全件洗い替え転送。updated_at で増分。」

### データマート定義（datamart_definition）
- `query`（実行 SQL）の要約: 何を集計/結合しているか
- 出力先データセット / テーブル、`write_disposition`（洗い替え/増分/SCD2）
- スケジュール

→ 例:「orders と users を JOIN し日次売上を集計、`analytics.daily_sales` へ増分更新（merge key: date, store_id）。」

### ワークフロー定義（pipeline_definition）
- `tasks` の種別と参照先定義名、`task_dependencies` の流れ
- スケジュール

→ 例:「注文転送 → 売上データマート生成の順で日次 5:00 実行。失敗時 Slack 通知。」

## 生成方針（一般ユーザー向けの注意）

- **事実ベース**: GET した設定に書かれていることだけを説明する。SQL の意図を過剰に推測しない。
- **簡潔**: 1〜3 文。「入力 → 処理 → 出力 → 頻度」の順が読みやすい。
- **PII / 秘匿情報を書かない**: 接続情報の認証値・個人情報・社外秘のテーブル名などを説明文に転記しない。
- **確認**: 生成した説明文はユーザーに提示し、承認を得てから PATCH する。既存の（簡素でも）説明を
  上書きする場合は before/after を必ず見せる。
