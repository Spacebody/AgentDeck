#!/bin/bash
# macOS GUI login session + Command Line Tools. Run: bash tests/test-install-macos.sh [all|health|launch]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SIGN_ID=fixture source "$here/../build.sh"

configure_fixture() {
  t="$1"
  BUNDLE_ID="local.agentdeck.install-test.${t##*.}"
  dest="$t/Applications/AgentDeck.app"
  APP="$t/dist/AgentDeck.app"
  pidfile="$t/Applications/running.pid"
}

# All process control and HTTP traffic are restricted to this run's fixture.
stop_running() {
  stop_fixture_pid "$pidfile"
}

stop_fixture_pid() {
  local file="$1" pid i
  [[ -f "$file" ]] || return 0
  pid="$(cat "$file")"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ "$(ps -p "$pid" -o comm=)" == "$dest/Contents/MacOS/Fixture" ]]; then
    kill "$pid" || return 1
    for i in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep .05; done
    ! kill -0 "$pid" 2>/dev/null || return 1
  fi
  rm -f "$file"
}

fetch_install_health() {
  local port
  port="$(cat "$t/Applications/$(cat "$pidfile").port")" || return 1
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  curl --noproxy '*' -fsS --max-time 2 "http://127.0.0.1:$port/api/health"
}

bundle() {
  local path="$1" version="$2" p="$1/Contents/Info.plist"
  mkdir -p "$path/Contents/MacOS" "$path/Contents/Resources"
  cp "$t/bin" "$path/Contents/MacOS/Fixture"
  cp "$here/fixtures/install/agentdeckd.py" "$path/Contents/Resources/"
  plutil -create xml1 "$p"
  plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$p"
  plutil -insert CFBundleExecutable -string Fixture "$p"
  plutil -insert CFBundlePackageType -string APPL "$p"
  plutil -insert CFBundleVersion -string "$version" "$p"
  plutil -insert CFBundleShortVersionString -string "$version" "$p"
  plutil -insert LSUIElement -bool true "$p"
  codesign -s - "$path"
}

install_fixture() {
  # A separate bash preserves install_app's errexit even in an expected-failure assertion.
  bash -c 'source "$1"; configure_fixture "$2"; install_app "$dest"' _ "${BASH_SOURCE[0]}" "$t"
}

expect_failure() {
  if install_fixture; then echo "Expected install failure" >&2; exit 1; fi
}

assert_live() {
  [[ "$(plutil -extract CFBundleVersion raw "$dest/Contents/Info.plist")" == "$1" ]]
  [[ "$(ps -p "$(cat "$pidfile")" -o comm=)" == "$dest/Contents/MacOS/Fixture" ]]
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
case "${1:-all}" in all|launch|health) suite="${1:-all}";; *) exit 2;; esac
[[ "$(uname -s)" == Darwin ]] || { echo 'Requires macOS' >&2; exit 1; }
t="$(mktemp -d "${TMPDIR:-/tmp}/agentdeck-install.XXXXXXXX")"
configure_fixture "$(cd "$t" && pwd -P)"
trap 'stop_fixture_pid "$t/Applications/hung.pid" && stop_running && rm -rf "$t"' EXIT
trap 'exit 1' HUP INT TERM
clang -framework AppKit "$here/fixtures/install/App.m" -o "$t/bin"
bundle "$dest" 1
launch_app "$dest" >/dev/null
assert_live 1
oldpid="$(cat "$pidfile")"

if [[ "$suite" != health ]]; then
  bundle "$APP" 3
  touch "$APP/Contents/extra"
  expect_failure
  assert_live 1
  [[ "$(cat "$pidfile")" == "$oldpid" ]]
  echo 'PASS invalid signature: old process untouched'
  rm "$APP/Contents/extra"
  expect_failure
  assert_live 1
  [[ "$(cat "$pidfile")" != "$oldpid" ]]
  echo 'PASS early exit: old bundle restored and relaunched'
  mv "$APP" "$t/broken.app"
  bundle "$APP" 4
  expect_failure
  assert_live 1
  hung="$(cat "$t/Applications/hung.pid")"
  if kill -0 "$hung" 2>/dev/null; then exit 1; fi
  echo 'PASS startup hang: stuck PID exited, old bundle restored and relaunched'
  mv "$APP" "$t/hung.app"
fi

bundle "$APP" 2
if [[ "$suite" != launch ]]; then
  oldpid="$(cat "$pidfile")"
  wait_install_health "$dest" 1 "$oldpid"
  for field in version pid parent_pid script_path; do
    echo "$field" > "$t/Applications/fault"
    if install_backend_ready "$dest" 1 "$oldpid"; then echo "Accepted wrong $field" >&2; exit 1; fi
  done
  expect_failure
  assert_live 1
  [[ "$(cat "$pidfile")" != "$oldpid" ]]
  rm "$t/Applications/fault"
  wait_install_health "$dest" 1 "$(cat "$pidfile")"
  echo 'PASS backend identity mismatch: old app and backend restored'
fi
install_fixture
assert_live 2
wait_install_health "$dest" 2 "$(cat "$pidfile")"
echo 'PASS successful upgrade: new app and owned backend running'
