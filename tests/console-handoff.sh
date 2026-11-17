#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
export AMOEBA_CAGE=1 AMOEBA_CAGE_BINARY="$temp/cage"
export AMOEBA_CONSOLE_VIEW_MARKER="$temp/viewing"
export TEST_DIR="$temp"
cat > "$AMOEBA_CAGE_BINARY" <<'SCRIPT'
#!/bin/sh
set -eu
test -f "$TEST_DIR/viewing"
test ! -e "$TEST_DIR/touch-reading"
case "${TEST_CAGE_MODE:-normal}" in
  blocked) exit 88 ;;
  crash) echo invoked > "$TEST_DIR/invoked"; exit 33 ;;
  hold)
    trap 'exit 0' TERM
    echo running > "$TEST_DIR/running"
    while :; do sleep .05; done ;;

esac
echo invoked > "$TEST_DIR/invoked"
SCRIPT
chmod +x "$AMOEBA_CAGE_BINARY"
: >"$temp/touch-reading"
(
  while [ ! -e "$temp/viewing" ]; do sleep .025; done
  sleep .15
  rm -f "$temp/touch-reading"
) &
release=$!
"$repo/bin/amoeba-view" "http://127.0.0.1:1/"
wait "$release"
test -e "$temp/invoked"
test ! -e "$temp/viewing"
if TEST_CAGE_MODE=crash "$repo/bin/amoeba-view" "http://127.0.0.1:1/"; then
  echo 'Expected failing viewer' >&2; exit 1
else
  test "$?" -eq 33
fi
test ! -e "$temp/viewing"
TEST_CAGE_MODE=hold "$repo/bin/amoeba-view" "http://127.0.0.1:1/" &
view=$!
tries=0
while [ ! -e "$temp/running" ] && [ "$tries" -lt 40 ]; do sleep .025; tries=$((tries + 1)); done
test -e "$temp/running"
kill -TERM "$view"
wait "$view"
test ! -e "$temp/viewing"
echo 'existing viewer' >"$temp/viewing"
if TEST_CAGE_MODE=blocked "$repo/bin/amoeba-view" "http://127.0.0.1:1/"; then
  echo 'Expected existing viewer guard' >&2; exit 1
else
  test "$?" -eq 1
fi
test "$(cat "$temp/viewing")" = 'existing viewer'
echo 'PASS touch ownership handoff, release on failure, and guard for an existing owner.'
