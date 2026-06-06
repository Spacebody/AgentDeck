#!/bin/bash
# CSRF 屏障回归测试：对运行中的 agentdeckd (127.0.0.1:7777) 跑攻击/合法矩阵
# 用法: ./scripts/test-csrf.sh   （全部通过输出 PASS，任一失败退出码 1）
set -u
BASE=http://127.0.0.1:7777
fail=0

chk() {  # chk <期望码> <描述> <curl 参数...>
  local want=$1 desc=$2; shift 2
  local got
  got=$(curl -s -o /dev/null -w "%{http_code}" "$@")
  if [ "$got" = "$want" ]; then
    echo "  ok   [$got] $desc"
  else
    echo "  FAIL [$got≠$want] $desc"; fail=1
  fi
}

echo "攻击变体（应 403）:"
chk 403 "无 Content-Type"            -X POST "$BASE/api/event" --data '{}'
chk 403 "text/plain"                 -X POST "$BASE/api/event" -H 'Content-Type: text/plain' --data '{}'
chk 403 "json+evil 子类型"           -X POST "$BASE/api/event" -H 'Content-Type: application/json+evil' --data '{}'
chk 403 "multipart"                  -X POST "$BASE/api/event" -H 'Content-Type: multipart/form-data' --data '{}'
chk 403 "外域 Origin"                -X POST "$BASE/api/settings" -H 'Content-Type: application/json' -H 'Origin: http://evil.com' -d '{}'
chk 403 "Origin 前缀绕过"            -X POST "$BASE/api/settings" -H 'Content-Type: application/json' -H 'Origin: http://127.0.0.1:7777.evil.com' -d '{}'
chk 403 "Origin scheme 混淆"         -X POST "$BASE/api/settings" -H 'Content-Type: application/json' -H 'Origin: https://127.0.0.1:7777' -d '{}'
chk 403 "DNS rebinding Host"         -X POST "$BASE/api/settings" -H 'Content-Type: application/json' -H 'Host: rebind.evil.com' -d '{}'

echo "合法调用（应 200）:"
chk 200 "标准 JSON"                  -X POST "$BASE/api/settings" -H 'Content-Type: application/json' -d '{}'
chk 200 "大小写+charset 参数"        -X POST "$BASE/api/settings" -H 'Content-Type: Application/JSON; charset=utf-8' -d '{}'
chk 200 "同源 Origin"                -X POST "$BASE/api/settings" -H 'Content-Type: application/json' -H 'Origin: http://127.0.0.1:7777' -d '{}'

[ $fail -eq 0 ] && echo "PASS" || { echo "FAILED"; exit 1; }
