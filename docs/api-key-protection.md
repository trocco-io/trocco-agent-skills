# API キーの保護

AI エージェントに TROCCO を操作させつつ、API キーの値をエージェントから参照させないための設定方法です。
キーの置き場所は 3 通りあります。通常はトークンファイルを使ってください。

| 方式 | キーの置き場所 | 必要なもの |
|---|---|---|
| トークンファイル（通常はこちら） | `~/.config/trocco/token`（パーミッション 600） | なし |
| 1Password | 1Password（`op run` の子プロセス内にのみ展開） | `op` CLI |
| 環境変数 | `$TROCCO_API_KEY` | なし |

このうち環境変数を使う場合は、エージェントが `printenv` などでキーの値を読めます。

いずれの方式でも、API 呼び出しはラッパー `trocco-api.sh` 経由です。ラッパーが `Authorization` ヘッダーを
所有し、`-v` / `--verbose` / `--trace`（ヘッダーがログに出力される）を拒否します。
キーは `--config` 経由で渡すため、`ps` などのプロセス引数にも現れません。

ラッパーは各スキルに `scripts/trocco-api.sh` として同梱されます。以下の動作確認コマンドは
`--target claude` でインストールした場合のパスです（`--target codex` などでは `.agents/` 配下になります）。
このリポジトリを clone して使う場合は、リポジトリルートの `bin/trocco-api.sh` が同じものです。

## トークンファイル

```bash
mkdir -p ~/.config/trocco
printf '%s' '＜あなたのAPIキー＞' > ~/.config/trocco/token
chmod 600 ~/.config/trocco/token
bash .claude/skills/audit-2fa/scripts/trocco-api.sh '/job_definitions?limit=10'
```

ラッパーが自身のサブプロセス内でファイルを読むため、キーはエージェントのシェル環境変数には現れません。

さらに、トークンファイル自体の読み取りを禁止しておくと、`cat` などで直接参照されることを防げます。

- Claude Code: `.claude/settings.json` に追加

  ```json
  { "permissions": { "deny": ["Read(~/.config/trocco/**)", "Bash(cat ~/.config/trocco/*)"] } }
  ```

- Codex: `~/.codex/config.toml` に追加し、キーをエージェントの環境変数に渡さない

  ```toml
  [shell_environment_policy]
  inherit = "all"
  ignore_default_excludes = false   # 既定では KEY/SECRET/TOKEN のフィルタが無効なため有効化する
  exclude = ["TROCCO_*"]
  ```

> [!NOTE]
> deny ルールは `bash -c` などの間接実行で回避される場合があります。
> 「意図せず参照させない」ための層と位置づけてください。

## 1Password

1Password を使っている場合は、キーをファイルにも置かずに済みます。

```bash
mkdir -p ~/.config/trocco
cp bin/.env.template ~/.config/trocco/.env   # clone していない場合は下記 2 行を直接書きます
# .env には、キーの実体ではなく op:// 参照だけを書きます:
#   TROCCO_API_KEY=op://Private/trocco-api-key/credential
eval "$(op signin)"                # 複数アカウントの場合は export TROCCO_OP_ACCOUNT=<account>
bash .claude/skills/audit-2fa/scripts/trocco-api.sh '/job_definitions?limit=10'
```

キーは `op run` が起動する子プロセスの環境変数としてのみ解決されます。
ディスクにも、エージェントが参照できるシェル環境にも現れません。

任意で、次の設定を追加するとより強固になります。

- Claude Code: `.claude/settings.json` に追加し、`op` の直接実行を禁止する

  ```json
  { "permissions": { "deny": ["Bash(op:*)"] } }
  ```

- Codex: `~/.codex/config.toml` に追加し、キーをエージェントの環境変数に渡さない

  ```toml
  [shell_environment_policy]
  inherit = "all"
  ignore_default_excludes = false   # 既定では KEY/SECRET/TOKEN のフィルタが無効なため有効化する
  exclude = ["TROCCO_*"]
  ```

## 環境変数

```bash
export TROCCO_API_KEY='＜あなたのAPIキー＞'
bash .claude/skills/audit-2fa/scripts/trocco-api.sh '/job_definitions?limit=10'
```

最も手軽ですが、**エージェントは環境変数からキーを参照できます**。
この方式を使う場合は、検証用アカウントや必要最小限の権限のキーを使うなど、影響範囲を絞る運用を推奨します。

## 漏洩ガード hook（Claude Code / Codex）

パッケージには PreToolUse hook が同梱され、`apm install` 時に自動配置されます
（Claude Code は `.claude/settings.json`、Codex は `.codex/hooks.json`）。
キー値の出力、`env` / `printenv` などのダンプ、`curl -v`、ラッパーを経由しない API 呼び出しを、
実行前に block します。

> [!IMPORTANT]
> hook には次の制約があります。
> - fail-open: hook の起動失敗やタイムアウト時、コマンドは実行されます（Codex の既知仕様）。
> - Codex: 初回に hook の承認が必要です。Windows では PreToolUse が発火しない既知の不具合があります。
>
> hook の有無にかかわらず、キー値を出力しない・ダンプしない・`-v` を使わない、という運用を前提としてください。
> 確実性を重視する場合は 1Password を使ってください。
