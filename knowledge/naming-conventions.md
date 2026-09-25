# 命名規則（Naming Conventions）: 導出と一括修正

> 2026-09-09 時点の公開仕様に基づく要約。齟齬があれば https://documents.trocco.io/apidocs.md を正とする。

定義名（`name`）の命名規則を実データから導出し、非準拠を一括修正するための知識。
まず [`trocco-api.md`](./trocco-api.md) を読むこと。

## `name` の API 制約（4 種共通・実確認済み）

| 種別 | index に name | 更新 | 補足フィールド（index） |
|---|---|---|---|
| 転送設定 job_definitions | ✅ | PATCH `name` | `input_option_type` / `output_option_type` |
| データマート datamart_definitions | ✅ | PATCH `name` | `data_warehouse_type` |
| ワークフロー pipeline_definitions | ✅ | PATCH `name` | なし |
| dbt ジョブ dbt_job_definitions | ✅ | PATCH `name` | `adapter_type` |

- **`maxLength: 255`**、**一意制約なし**、**pattern 制約なし**。
- `name` は index に含まれるので**列挙は per-id GET 不要**。`name` はスカラーなので **PATCH は 1 項目だけ**送れば他は保持。
- 一意制約は無いが、**重複名は運用上まぎらわしい**ので提案名の衝突は検出して警告する。
- リネームは**ワークフローのタスク参照を壊さない**（参照は id ベース）。可逆（`name` を戻せる）。

## 命名テンプレート（叩き台）

| 種別 | テンプレート |
|---|---|
| 転送設定 | `<env>_<PJ>_<成果物名(table/task)>_<転送元コネクタ>_<転送先コネクタ>` |
| データマート | `<env>_<PJ>_<成果物名>`（DWH は 1 つ前提で自明として含めない） |
| ワークフロー | `<env>_<PJ>_<成果物名>` |
| dbt ジョブ | `<env>_<PJ>_<成果物名>` |

> これは初期値。実データからの導出結果と突き合わせ、ユーザー確認で確定する。

## 規則の導出（実データから）

index の `name` を分析して提示する:

- **区切り文字**: `_` / `-` などの頻度から推定（既定 `_`）。
- **セグメント数の分布**: 例「転送の 78% が 5 セグメント」。
- **env 語彙候補**: 先頭セグメントの頻度上位（`prod` / `stg` / `dev` など）。
- **PJ 候補**: 2 番目セグメントの頻度上位。
- **転送のコネクタ接尾辞**: 末尾 2 セグメントが実際の `input_option_type` / `output_option_type` と
  一致するかを検証（**コネクタは名前推測でなく API を正**とする）。

```bash
# 例: 転送名のセグメント数分布
fetch_all job_definitions | jq -r '.name | (split("_")|length)' | sort | uniq -c
```

## トークンの決定可否（自動補完 vs 要ユーザー判断）

**ルール: 正しい値が決定できるトークンだけ自動修正。発明が要るものはレポートに回す。**

| トークン | 決定方法 | 自動補完? |
|---|---|---|
| 転送 `<src>_<dst>` | API `input_option_type` / `output_option_type` | ✅ 自動 |
| データマート `<成果物名>` | detail GET の `destination_table`（`query_mode=insert` 時） | ✅ 自動 |
| 転送 `<成果物名>` | detail GET の出力オプション table が単一・自明な場合 | ✅ 条件付き自動 |
| `<env>` / `<PJ>` | 既存名に確定語彙のトークンがあれば正規化 | ✅ 認識時のみ |
| ワークフロー / dbt `<成果物名>` | API に単一の出力先が無い | ❌ 要判断 |
| データマート `query_mode=query` の成果物名 | 出力先テーブルが無い | ❌ 要判断 |
| `<env>` / `<PJ>` が欠落 | 発明が必要 | ❌ 要判断 |

- 成果物名の補完には **detail GET が必要**（index には出力先テーブルが無い）。対象のみ絞って GET する。
- `destination_table` に `$date$` 等の**カスタム変数/式・パス・複数**が含まれる場合は自明でない → 要判断。

## 一括修正フロー

1. index で全名称＋補足フィールドを列挙。
2. 規則を導出し、テンプレ・env/PJ 語彙・区切りをユーザーに提示 → **承認で確定**。
3. 各リソースを準拠 / 非準拠に分類。非準拠は提案名を生成:
   - 決定可能トークンを自動補完（上表）。
   - 決定不能トークンがあるものは **「要ユーザー判断」レポート**（部分提案＋不足スロットを明示）。
4. **衝突チェック**（提案名どうし / 既存名）と **255 超過**チェック。
5. 提示 → 承認 → `name` を一括 PATCH（例: `-d '{"name":"prod_sales_orders_mysql_bigquery"}'`）。
6. まず少数で適用 → GET で反映確認 → 横展開。変更 id 一覧を報告。

```bash
# 例: 転送設定のリネーム（name のみ差分更新）
trocco-api.sh -X PATCH -H 'Content-Type: application/json' \
  "/job_definitions/<id>" -d '{ "name": "prod_sales_orders_mysql_bigquery" }'
```
