#!/bin/sh
# AgentDeck codex notify wrapper
# 用法：将 ~/.codex/config.toml 的 notify 指向本脚本（见 README「可选配置」）。
# Codex 在每个 turn 结束时以 JSON 参数调用 notify 命令，本脚本将其转发给
# 本机 AgentDeck daemon 用于「会话完成提醒」。若原 notify 已有其他命令，
# 可在脚本末尾追加 exec 原命令进行链式转发。
JSON="$1"
curl -sf -m 3 -X POST http://127.0.0.1:7777/api/event \
  -H 'Content-Type: application/json' --data-binary "$JSON" >/dev/null 2>&1
