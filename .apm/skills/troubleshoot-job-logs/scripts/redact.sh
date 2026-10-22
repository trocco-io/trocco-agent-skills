#!/usr/bin/env bash
# 実行ログ・定義を伏せ字にして標準出力に出す。AI が生ログを直接読まないための入口。
#
#   redact.sh allow <file>                 許可リスト方式（既定）。行番号付きで全行を出す
#   redact.sh mask  <file> <start> <end>   個別に許可された行範囲だけを、マスキング方式で出す
#   redact.sh json  <file>                 定義の詳細（JSON）を伏せ字にする
#
# 規則は同じディレクトリの redact.jq にある。
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jqprog="$dir/redact.jq"
die() { printf 'redact: %s\n' "$1" >&2; exit 1; }

mode="${1:-}"; file="${2:-}"
[ -n "$mode" ] && [ -n "$file" ] || die "usage: redact.sh allow|mask|json <file> [start end]"
[ -f "$file" ] || die "ファイルがありません: $file"

case "$mode" in
  allow) jq -Rrs --arg mode allow --arg start 0 --arg end 0 -f "$jqprog" "$file" ;;
  mask)
    start="${3:-}"; end="${4:-}"
    case "$start$end" in *[!0-9]*|"") die "mask には行範囲（start end）が必要です" ;; esac
    [ $((end - start)) -le 200 ] || die "mask で一度に出せるのは 200 行までです（範囲を絞ってください）"
    jq -Rrs --arg mode mask --arg start "$start" --arg end "$end" -f "$jqprog" "$file" ;;
  json) jq --arg mode json --arg start 0 --arg end 0 -f "$jqprog" "$file" ;;
  *) die "不明なモード: $mode" ;;
esac
