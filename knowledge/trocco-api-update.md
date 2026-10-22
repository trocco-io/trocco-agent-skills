# TROCCO API: 更新（PATCH）の挙動とエラーレスポンス

> 2026-10-20 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

定義や設定を**変更する** skill が前提とする知識。読み取りだけの skill には不要。
先に [`trocco-api.md`](./trocco-api.md)（ラッパー・ページネーション・共通ルール）を読むこと。

```bash
# 例: 更新（PATCH）
trocco-api.sh /job_definitions/123 -X PATCH \
  -H 'Content-Type: application/json' -d @payload.json
```

## 差分更新だが配列は洗い替え

`job_definition` / `datamart_definition` / `pipeline_definition` の更新はいずれも
**スカラー項目は差分更新（送った項目だけ変わる）／配列項目は洗い替え（送った配列で全置換）** という
セマンティクスを持つ。OpenAPI の記述より:

> 基本的に差分更新です。配列要素については洗い替えとなるため、すべての要素を指定する必要があります。
> 配列要素を空にしたい場合明示的に空配列を指定してください。

これが意味すること:

- **スカラー**（`resource_group_id`, `description`, `name` など）→ その項目だけ PATCH すれば OK。他項目は保持される。
  - 実測: `job_definition` に `description` だけを PATCH しても、`filter_columns` / `input_option` /
    `output_option` / `schedules` はすべて保持された。
- **配列**（`notifications`, `schedules`, `labels` など）→ 送った配列が既存を**全置換**する。
  - 通知を「追加」したい場合は **既存を GET → 配列に append → 全量を PATCH** する（既存通知を消さないため）。
  - `[]` を送ると全削除される。**未指定なら変更されない**（差分更新のため）。
  - 例外: データマート定義の `column_descriptions` は、送らなかったカラムを変更しない。

> [!CAUTION]
> **この差分更新は上記 3 種の定義だけの話**。チームとリソースグループには当てはまらない。
>
> | エンドポイント | PATCH の必須項目 | 送らなかった場合 |
> |---|---|---|
> | `/teams/:id` | `name`, `members` | HTTP 500 |
> | `/resource_groups/:id` | `name` | エラー |
>
> これらは更新前に detail を GET し、変更しない項目も含めて全量を送ること。
> 詳細は teams.md / resource-groups.md を参照。

## ネストオブジェクトは部分更新

ネストオブジェクトも**部分更新**だった（実測）。変えたい項目だけを入れ子で送れば、同じオブジェクト内の
他の項目は保持される。

- データマートの `datamart_bigquery_option`: `write_disposition` だけを送っても、`query`（1 万文字超）・
  `destination_dataset` / `destination_table` / `bigquery_connection_id` は保持された。
- 転送設定の `output_option`: `mode` だけを送っても、出力先データセット / テーブル・接続 ID・
  ロケーションは保持された。
- 転送設定の `input_option`: 1 項目だけを送っても、入力カラム定義（100 件近く）は保持された。

いずれもオブジェクト外の項目（`filter_columns` / `schedules` / `notifications` /
`resource_group_id`）にも影響しなかった。

> [!CAUTION]
> **GET の結果をそのまま PATCH に投げ返すと失敗することがある**。GET レスポンスと PATCH 入力の
> スキーマは一致しない。ワークフローでは実際に、API が自身の GET 出力を 400 で拒否する
> （`tasks[].key` が GET に含まれず、`task_dependencies` が整数で返るため。workflows.md 参照）。
> 複雑な変更は 1 項目ずつ構築し、実行前に必ずユーザーへ差分を提示すること。

## エラーレスポンスの形が一定しない

400 の本文は少なくとも 3 種類ある。どれか 1 つを前提にパースしない。

```json
{"message":"Bad request. Please check your request payload","errors":[{"attribute":"incremental_column","message":"Incremental columnを入力してください。"}]}
{"message":"Tasks keyが必要です, Task dependenciesは無効な 配列 です","errors":[]}
{"error":"タスクの依存関係が不正です"}
```

- `errors[].attribute` があるときは、どの項目が足りないかを特定できる。ユーザーへの報告に使う。
- **404 `Not found` はリソース不在とは限らない**。ワークフローの PATCH では、タスクの `type` と
  `definition_id` の種別が食い違うときにも 404 が返る（対象のワークフローは存在している）。
