# API キーの取り扱いルール

TROCCO の API キーはアカウントを操作できる資格情報。値を露出させない。
本ルールは PreToolUse hook で機械的に強制する。

## 大原則: API は `bin/trocco-api.sh` 経由で呼ぶ

`curl` で TROCCO API を直接叩かない。ベース URL と `Authorization` ヘッダーはラッパーが
所有するので、パス以降と curl 引数だけを渡す。キーの値を読む必要はない。

```bash
bin/trocco-api.sh '/job_definitions?limit=200'
bin/trocco-api.sh /job_definitions/123 -X PATCH \
  -H 'Content-Type: application/json' -d @payload.json
```

ラッパーが資格情報を解決するため、キーの在り処を調べる必要はない。

## 禁止事項（hook が block する）

- キー値を出力しない: `echo $TROCCO_API_KEY` / `printf ... ${TROCCO_API_KEY}` など。
- 環境変数をダンプしない: `printenv` / 引数なし `env` / `declare -p` / `export -p` / `/proc/*/environ`。
- `curl` の verbose/trace を使わない: `-v` / `--verbose` / `--trace*`（Authorization ヘッダーがログに出る）。
- ラッパーを使わない API 直叩きをしない（`curl ... trocco.io/api ...`）。

## その他の遵守事項（hook 対象外・運用で守る）

- キー値をファイルに書き出さない、コミットしない。
- エラー報告時もキーの値を引用しない。
- 通信先は TROCCO API に限定し、キーを外部へ送らない。

## hook の限界

hook は起動失敗やタイムアウト時にコマンドを通してしまう（fail-open）。
block されなかったことを許可の根拠にせず、上記の規約そのものを守る。
