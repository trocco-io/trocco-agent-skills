#!/usr/bin/env bash
# TROCCO API 用の curl ラッパー。
#
# 目的: AI エージェントに API を使わせつつ、API キーの「値」を極力見せない。
# エージェントは **パス以降と curl 引数だけ** を渡す。Authorization ヘッダーと
# ベース URL はこのスクリプトが所有する。
#
#   trocco-api.sh /job_definitions?limit=200
#   trocco-api.sh /teams/1
#   trocco-api.sh /job_definitions/123 -X PATCH \
#     -H 'Content-Type: application/json' -d @payload.json
#
# このファイルは各スキルの scripts/trocco-api.sh にも複製されて配布される
# （canonical はこの bin/ 版。複製は scripts/sync-references.sh が生成する）。
# 置かれる場所が変わるため、スクリプト自身の位置に依存する処理を書かないこと。
#
# 資格情報の解決（上から順に試す。詳細は docs/api-key-protection.md 参照）:
#   Tier 1  1Password: .env（op:// 参照のみ）+ op run
#   Tier 2  トークンファイル: ~/.config/trocco/token (chmod 600)
#   Tier 3  環境変数 TROCCO_API_KEY                     … エージェントから値が読める
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${TROCCO_API_BASE_URL:-https://trocco.io/api}"
TOKEN_FILE="${TROCCO_TOKEN_FILE:-$HOME/.config/trocco/token}"

die() { printf 'trocco-api: %s\n' "$1" >&2; exit 1; }

[ "$#" -ge 1 ] || die "usage: trocco-api.sh <path> [curl args...]   (例: /job_definitions?limit=200)"

# --- verbose/trace 系は拒否する ---------------------------------------------
# これらは Authorization ヘッダー（＝キー）を標準エラーに出力してしまうため、
# ラッパーの意味が無くなる。短縮フラグの結合（-sSv 等）も検出する。
for arg in "$@"; do
  case "$arg" in
    --verbose|--trace|--trace-ascii|--trace-config|--trace-ids|--trace-time)
      die "$arg はキーを含むヘッダーをログに出すため使用できません。" ;;
    --*) : ;;
    -*[vV]*)
      die "$arg (-v/-V) はキーを含むヘッダーをログに出すため使用できません。" ;;
  esac
done

# --- Tier 1: 1Password (op run) ---------------------------------------------
# .env には op:// 参照のみを書く（実体は書かない）。op run が子プロセスの環境変数
# としてだけ解決するので、キーは親シェルにもディスクにも現れない。
#
# このスクリプトは bin/ にも各スキルの scripts/ にも置かれるため、.env は
# スクリプトの位置ではなく決まった候補から探す（TROCCO_ENV_FILE で明示指定も可）。
env_file=""
for cand in "${TROCCO_ENV_FILE:-}" "$HOME/.config/trocco/.env" "$PWD/bin/.env" "${script_dir}/.env"; do
  if [ -n "$cand" ] && [ -f "$cand" ]; then env_file="$cand"; break; fi
done

if [ -z "${_TROCCO_ENV:-}" ] && [ -n "$env_file" ] && command -v op >/dev/null 2>&1; then
  op_args=(op run --env-file="$env_file")
  [ -n "${TROCCO_OP_ACCOUNT:-}" ] && op_args+=(--account "${TROCCO_OP_ACCOUNT}")
  exec env _TROCCO_ENV=1 "${op_args[@]}" -- "$0" "$@"
fi

# --- Tier 2: トークンファイル -------------------------------------------------
# サブプロセス（このスクリプト）の中でだけ読む。親シェル/エージェントの環境変数には出さない。
if [ -z "${TROCCO_API_KEY:-}" ] && [ -r "$TOKEN_FILE" ]; then
  TROCCO_API_KEY="$(tr -d '\r\n' < "$TOKEN_FILE")"
fi

# --- Tier 3: 環境変数 ---------------------------------------------------------
[ -n "${TROCCO_API_KEY:-}" ] || die "API キーが見つかりません。docs/api-key-protection.md を参照して
  トークンファイル ($TOKEN_FILE) / 1Password (~/.config/trocco/.env + op) / 環境変数 TROCCO_API_KEY
  のいずれかを設定してください。"

# --- リクエスト ---------------------------------------------------------------
# パスは第 1 引数が基本だが、curl 流に `-X PATCH ... /path` と書かれても動くよう、
# 先頭が `-` の場合は「最初の `/` で始まる引数」をパスとして取り出す。
if [ "${1#-}" != "$1" ]; then
  api_path=""; rest=()
  for arg in "$@"; do
    if [ -z "$api_path" ] && [ "${arg#/}" != "$arg" ]; then api_path="$arg"; else rest+=("$arg"); fi
  done
  [ -n "$api_path" ] || die "API パスが見つかりません（例: /job_definitions）。"
  set -- "${rest[@]+"${rest[@]}"}"
else
  api_path="$1"; shift
fi

case "$api_path" in
  http://*|https://*) die "URL 全体ではなく、パス以降を渡してください（例: /job_definitions）。" ;;
  /*) : ;;
  *) api_path="/$api_path" ;;
esac

# --- レートリミット対応 -------------------------------------------------------
# TROCCO API は 10 分あたりの呼び出し上限がある（トライアル 100 / Advanced 以上 3,500）。
# 超過すると 429 が返る。レスポンスヘッダー X-Rate-Limit-Reset（UNIX 時刻）まで待って
# 自動リトライする。待ち時間は TROCCO_MAX_WAIT 秒で上限を設ける（既定 120 秒）。
#   リトライ無効化: TROCCO_NO_RETRY=1
max_retry="${TROCCO_MAX_RETRY:-3}"
max_wait="${TROCCO_MAX_WAIT:-120}"
[ -n "${TROCCO_NO_RETRY:-}" ] && max_retry=0

# 自動リトライは出力系オプション（-o / -D / -w）を内部で使う。呼び出し側がこれらを
# 指定している場合は競合するため、curl にそのまま委譲する（この場合は自動リトライ無し）。
for arg in "$@"; do
  case "$arg" in
    -o|--output|-O|--remote-name|-D|--dump-header|-w|--write-out)
      exec curl -sS --fail-with-body \
        --config <(printf 'header = "Authorization: Token %s"\n' "$TROCCO_API_KEY") \
        "${BASE_URL}${api_path}" "$@" ;;
  esac
done

hdr="$(mktemp "${TMPDIR:-/tmp}/.trocco_hdr.XXXXXX")"
body="$(mktemp "${TMPDIR:-/tmp}/.trocco_body.XXXXXX")"
trap 'rm -f "$hdr" "$body"' EXIT

attempt=0
while : ; do
  # Authorization ヘッダーは --config 経由でファイルディスクリプタとして渡す。
  # -H に直接展開するとキーがプロセスの引数（ps で参照可能）に載るため。
  # printf は bash の組み込みコマンドなので、ここでも別プロセスの引数には現れない。
  code="$(curl -sS -o "$body" -D "$hdr" -w '%{http_code}' \
    --config <(printf 'header = "Authorization: Token %s"\n' "$TROCCO_API_KEY") \
    "${BASE_URL}${api_path}" "$@")" || true

  if [ "$code" != "429" ] || [ "$attempt" -ge "$max_retry" ]; then
    break
  fi

  # X-Rate-Limit-Reset（UNIX 時刻）まで待つ。取得できなければ指数バックオフ。
  reset="$(tr -d '\r' < "$hdr" | awk 'tolower($1)=="x-rate-limit-reset:"{print $2}')"
  now="$(date +%s)"
  if [ -n "$reset" ] && [ "$reset" -gt "$now" ] 2>/dev/null; then
    wait_sec=$(( reset - now + 1 ))
  else
    wait_sec=$(( 2 ** attempt * 5 ))
  fi
  [ "$wait_sec" -gt "$max_wait" ] && \
    die "レートリミット超過。リセットまで ${wait_sec}s 必要ですが上限 ${max_wait}s を超えるため中断します（TROCCO_MAX_WAIT で調整可）。"

  printf 'trocco-api: レートリミット超過。%s 秒待って再試行します (%s/%s)\n' \
    "$wait_sec" "$((attempt + 1))" "$max_retry" >&2
  sleep "$wait_sec"
  attempt=$((attempt + 1))
done

# ユーザーが -o を渡した場合は curl がそちらへ書くため、本文が空なら何も出さない。
if [ -s "$body" ]; then cat "$body"; fi
# 4xx/5xx は curl の --fail-with-body 相当の終了コードで返す（本文は出力済み）。
case "$code" in
  2*) exit 0 ;;
  429) printf 'trocco-api: レートリミット超過が解消しませんでした (HTTP 429)\n' >&2; exit 22 ;;
  *) printf 'trocco-api: HTTP %s\n' "$code" >&2; exit 22 ;;
esac
