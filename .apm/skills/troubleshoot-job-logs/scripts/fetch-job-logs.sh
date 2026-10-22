#!/usr/bin/env bash
# ジョブの実行結果・実行ログ・定義の詳細を取得し、伏せ字にしたものだけを作業ディレクトリに置く。
#
#   fetch-job-logs.sh <jobs|datamart_jobs|dbt_jobs> <job_id> [作業ディレクトリ]
#
# 生データは <作業ディレクトリ>/.raw/ に権限 600 で保存する。AI はここを直接読まない
# （読むのは redact.sh 経由だけ）。標準出力には伏せ字済みの要約だけを出す。
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="$dir/trocco-api.sh"
R="$dir/redact.sh"
die() { printf 'fetch-job-logs: %s\n' "$1" >&2; exit 1; }

kind="${1:-}"; id="${2:-}"
case "$kind" in jobs|datamart_jobs|dbt_jobs) : ;; *) die "usage: fetch-job-logs.sh <jobs|datamart_jobs|dbt_jobs> <job_id> [dir]" ;; esac
case "$id" in ""|*[!0-9]*) die "job_id は数字で指定してください" ;; esac
out="${3:-${TMPDIR:-/tmp}/trocco_troubleshoot_${kind}_${id}}"
raw="$out/.raw"

umask 077
mkdir -p "$raw"

# --- 実行結果 -----------------------------------------------------------------
bash "$W" "/$kind/$id" > "$raw/job.json" || die "実行結果を取得できませんでした（上の HTTP ステータスを参照）"

case "$kind" in
  jobs)          def_key=job_definition_id;      def_path=/job_definitions ;;
  datamart_jobs) def_key=datamart_definition_id; def_path=/datamart_definitions ;;
  dbt_jobs)      def_key=dbt_job_definition_id;  def_path=/dbt_job_definitions ;;
esac

# 定義名・メモ・実行クエリは利用者が自由に書く文字列なので、要約には出さない
jq --arg k "$def_key" '{id, ($k): .[$k], status, executor_type, context_time, started_at, finished_at,
    transfer_record, transfer_byte, skipped_row_count, pipeline_job_id, dbt_job_definition_revision_id}
  | with_entries(select(.value != null))' "$raw/job.json" > "$out/job.json"

if jq -e '.executed_query // empty' "$raw/job.json" > /dev/null; then
  jq -r '.executed_query' "$raw/job.json" > "$raw/executed_query.sql"
  bash "$R" allow "$raw/executed_query.sql" > "$out/executed_query.txt"
fi

# --- 実行ログ -----------------------------------------------------------------
bash "$W" "/$kind/$id/logs" > "$raw/logs.json" || die "実行ログを取得できませんでした（503 なら Retry-After の秒数だけ待って再実行）"
jq '[.logs.streams[] | {type, status, truncated, byte_size}]' "$raw/logs.json" > "$out/streams.json"
for t in $(jq -r '.logs.streams[] | select(.status == "available") | .type' "$raw/logs.json"); do
  jq -r --arg t "$t" '.logs.streams[] | select(.type == $t) | .content' "$raw/logs.json" > "$raw/$t.txt"
  bash "$R" allow "$raw/$t.txt" > "$out/$t.txt"
done

# --- 定義の詳細 ---------------------------------------------------------------
def_id="$(jq -r --arg k "$def_key" '.[$k] // empty' "$raw/job.json")"
def_note=""
if [ -n "$def_id" ]; then
  # 整形して保存する（redact.sh mask の行範囲指定で一部だけを見られるように）
  if bash "$W" "$def_path/$def_id" 2>/dev/null | jq . > "$raw/definition.json"; then
    bash "$R" json "$raw/definition.json" > "$out/definition.json"
  else
    def_note="定義の詳細を取得できませんでした（転送設定の一部コネクタは 400 で未サポート。ログだけで判断する）"
    rm -f "$raw/definition.json"
  fi
fi

# --- 要約 ---------------------------------------------------------------------
echo "== job (redacted) =="; cat "$out/job.json"
echo "== streams =="; jq -r '.[] | [.type, .status, .truncated, .byte_size] | @tsv' "$out/streams.json"
echo "== files (AI はこれだけを読む。.raw/ は読まない) =="
for f in "$out"/*.txt "$out"/*.json; do [ -f "$f" ] && printf '%s\t%s lines\n' "$f" "$(wc -l < "$f" | tr -d ' ')"; done
[ -n "$def_note" ] && echo "$def_note"
exit 0
