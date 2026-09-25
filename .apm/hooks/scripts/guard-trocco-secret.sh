#!/usr/bin/env bash
# PreToolUse(Bash) ガード — API キーの値が漏れる操作を実行前に block する。
#
# 対応ハーネス: Claude Code / Codex（deny プロトコルに互換性があるため 1 本で両対応）。
# apm が各ハーネスの設定へ配布する（.claude/settings.json, .codex/hooks.json など）。
#
# 設計上の注意:
# - **jq に依存しない**。Codex の hook は spawn 失敗・異常終了時に "fail open"（＝コマンドが実行される）
#   ため、依存を増やすとガードが静かに無効化される。生の stdin をシェル組み込みだけで処理する。
# - **JSON deny と exit 2 + stderr を併用**する。ハーネスによって解釈が異なるため両方出す。
# - **キーの値を出力しない**。hook の出力はディスクに書き出されることがある。
set -u

input="$(cat)"

# stdin から .tool_input.command を取り出す（jq なし。sed は POSIX 標準で必ず存在する）。
# 想定: {"tool_name":"Bash","tool_input":{"command":"..."},...}
# コマンド中の \" を正しく扱う必要があるため、エスケープ対応の正規表現で抽出する。
case "$input" in
  *'"command"'*) : ;;
  *) exit 0 ;;   # command を持たないペイロード（Bash 以外など）は対象外
esac
cmd="$(printf '%s' "$input" \
  | sed -E 's/.*"command"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/')"
# 抽出に失敗した場合（想定外の形）は、取りこぼすより安全側に倒してペイロード全体を検査する。
if [ -z "$cmd" ] || [ "$cmd" = "$input" ]; then
  cmd="$input"
fi

deny() {
  # Claude Code / Codex 共通の JSON 形式
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  # exit 2 + stderr でもブロックできるハーネス向け
  printf 'trocco guard: %s\n' "$1" >&2
  exit 2
}

# 1) キー値の出力
case "$cmd" in
  *echo*TROCCO_API_KEY*|*printf*TROCCO_API_KEY*|*print*TROCCO_API_KEY*)
    deny "TROCCO_API_KEY の値を出力しようとしています。キー値は表示せず、ラッパー trocco-api.sh 経由で使用してください。" ;;
esac

# 2) 環境変数のダンプ
case "$cmd" in
  *printenv*)   deny "printenv は環境変数（API キーを含む）を露出します。使用しないでください。" ;;
  env|env\ *\|*|*\;env|*\;env\ *|*\&\&env*|env)
                deny "引数なし env は全環境変数を露出します。使用しないでください。" ;;
  *declare\ -p*|*export\ -p*|*typeset\ -p*)
                deny "declare/export -p は変数値を露出します。使用しないでください。" ;;
  */proc/*/environ*)
                deny "/proc/*/environ の参照は環境変数を露出します。" ;;
esac

# 3) curl の verbose/trace（Authorization ヘッダーがログに出る）
case "$cmd" in
  *curl*)
    case "$cmd" in
      *--verbose*|*--trace*)
        deny "curl の --verbose/--trace はキーを含むヘッダーをログに出します。使用しないでください。" ;;
    esac
    # 短縮フラグ（-v, -sSv 等）。--long-option の中の v は誤検知しないよう空白区切りで判定。
    case " $cmd " in
      *\ -[!-]*v*\ *|*\ -v\ *|*\ -v)
        deny "curl の -v はキーを含むヘッダーをログに出します。使用しないでください。" ;;
    esac
    # 4) ラッパーを使わない TROCCO API 直叩き
    case "$cmd" in
      *trocco-api.sh*) : ;;   # ラッパー経由は OK
      *trocco.io/api*|*TROCCO_API_KEY*)
        deny "TROCCO API はラッパー trocco-api.sh 経由で呼び出してください（キーを露出させないため）。" ;;
    esac ;;
esac

exit 0
