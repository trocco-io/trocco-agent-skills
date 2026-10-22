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
    # 短縮フラグ（-v, -sSv 等）。単語ごとに判定する。コマンド全体へのパターンだと `*` が空白を
    # またぎ、`-G https://.../api/v2` のように後続の URL に含まれる v まで拾ってしまう。
    # --long-option の中の v は対象外。展開でファイル名に化けないよう glob を止めてから分割する。
    set -f
    for w in $cmd; do
      w="${w#[\'\"]}"
      case "$w" in
        --*) : ;;
        -*v*) set +f
              deny "curl の -v はキーを含むヘッダーをログに出します。使用しないでください。" ;;
      esac
    done
    set +f
    # 4) ラッパーを使わない TROCCO API 直叩き
    case "$cmd" in
      *trocco-api.sh*) : ;;   # ラッパー経由は OK
      # ホストが trocco.io そのものの場合だけを対象にする。help.trocco.io/api/v2/...（ヘルプセンター）や
      # documents.trocco.io/apidocs.md（公式ドキュメント）は API キーを使わないため止めない。
      *[!.A-Za-z0-9-]trocco.io/api*|*TROCCO_API_KEY*)
        deny "TROCCO API はラッパー trocco-api.sh 経由で呼び出してください（キーを露出させないため）。" ;;
    esac ;;
esac

# 5) 伏せ字にする前の生ログ・生の定義（troubleshoot-job-logs の作業ディレクトリの .raw/）を直接読む操作
#    実行ログにはホスト名・ユーザー名・データの値が含まれるため、AI の入力に入れない。
#    読むのは redact.sh 経由だけ。生成（fetch-job-logs.sh）と削除（rm）は許可する。
#    hook は fail-open で、複数のコマンドを連結すれば素通りしうるので、あくまで手順の補助。
case "$cmd" in
  *.raw/*|*/.raw|*/.raw\ *|*/.raw\"*|*/.raw\'*)
    case "$cmd" in
      *redact.sh*|*fetch-job-logs.sh*) : ;;
      rm\ *) : ;;
      *) deny "伏せ字前の生ログ（.raw/）は直接読まないでください。redact.sh 経由で読んでください。" ;;
    esac ;;
esac

exit 0
