#!/usr/bin/env bash
# sync-references.sh
#
# 各スキルを「自己完結」に保つための同期スクリプト。
# canonical な共有ドキュメントは `knowledge/` に単一ソースで置き、
# 各 `.apm/skills/<name>/SKILL.md` が参照する `./references/<doc>.md` を
# `knowledge/<doc>.md` からコピーして生成する（apm 配布時に skill と一緒に運ばれる）。
#
# SKILL.md 内の `./references/<name>.md` リンクを走査し、対応する canonical を
# references/ に反映する。canonical に無い参照は WARN（各スキル固有ドキュメントは
# そのまま references/ に置いてよい＝canonical 不要）。
#
# API ラッパー `bin/trocco-api.sh` も同じ考え方で各スキルの `scripts/` へ複製する。
# apm が消費側プロジェクトへ配るのはスキルディレクトリの中身だけで、リポジトリルートの
# `bin/` は運ばれない。スキルに同梱しないと、apm 経由の利用者はラッパーを呼び出せない。
#
# 使い方: リポジトリルートで `bash scripts/sync-references.sh`
# CI では `--check` で差分があれば失敗させる。
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
drift_flag="$(mktemp)"; tmp_render="$(mktemp)"; trap 'rm -f "$drift_flag" "$tmp_render"' EXIT

# canonical doc を references/ 用にレンダリング:
# skill に同梱されない相対リンク（doc-to-doc の ./x.md / ../*.md / ../rules/*.md）は
# 配置後に解決しないため、リンクを外してテキスト化する。SKILL.md 側の ./references/ リンクは対象外。
render() {
  sed -E 's/\[([^][]+)\]\((\.\.?\/)[A-Za-z0-9._/-]+\.md\)/\1/g' "$1"
}

for skill in .apm/skills/*/; do
  md="${skill}SKILL.md"
  [ -f "$md" ] || continue
  # SKILL.md が参照する ./references/<doc>.md を抽出
  for doc in $(grep -oE '\./references/[A-Za-z0-9._-]+\.md' "$md" 2>/dev/null | sed 's#\./references/##' | sort -u); do
    src="knowledge/$doc"
    dst="${skill}references/$doc"
    if [ ! -f "$src" ]; then
      # canonical が無い = スキル固有ドキュメント（references/ に直接存在する想定）
      [ -f "$dst" ] || echo "WARN: $md references $doc but neither knowledge/$doc nor $dst exists"
      continue
    fi
    mkdir -p "${skill}references"
    render "$src" > "$tmp_render"
    if [ "$CHECK" = "1" ]; then
      if ! cmp -s "$tmp_render" "$dst"; then
        echo "DRIFT: $dst is out of sync with $src (run: bash scripts/sync-references.sh)"
        echo x >> "$drift_flag"
      fi
    else
      cp "$tmp_render" "$dst"
    fi
  done

  # API ラッパーを同梱する。実行ビットごと複製され、apm がスキルごと配布する。
  wrapper_dst="${skill}scripts/trocco-api.sh"
  if [ "$CHECK" = "1" ]; then
    if ! cmp -s bin/trocco-api.sh "$wrapper_dst"; then
      echo "DRIFT: $wrapper_dst is out of sync with bin/trocco-api.sh (run: bash scripts/sync-references.sh)"
      echo x >> "$drift_flag"
    fi
  else
    mkdir -p "${skill}scripts"
    cp bin/trocco-api.sh "$wrapper_dst"
    chmod +x "$wrapper_dst"
  fi
done

[ -s "$drift_flag" ] && exit 1 || exit 0
