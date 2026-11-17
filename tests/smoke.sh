#!/bin/sh
# Run in an isolated login/session when another preview is not active.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temp=$(mktemp -d)
project=$temp/signal-rooms
export AMOEBA_RUNTIME_DIR=$temp
export AMOEBA_PCM=null
export DISPLAY=:${AMOEBA_TEST_DISPLAY:-91}
export AMOEBA_TEST_PORT=${AMOEBA_TEST_PORT:-18791}
export AMOEBA_TEST_BROWSER=${AMOEBA_BROWSER:-chromium}
export AMOEBA_TEST_PID=$temp/browser.pid
export AMOEBA_BROWSER=$temp/browser
xvfb=
view=
cleanup() {
  if [ -s "$AMOEBA_TEST_PID" ]; then kill "$(cat "$AMOEBA_TEST_PID")" 2>/dev/null || true; fi
  if [ -n "$view" ]; then kill "$view" 2>/dev/null || true; fi
  if [ -e "$temp/amoeba-daw-session.sexp" ]; then "$repo/bin/amoeba" "$project" session end >/dev/null || true; fi
  if [ -n "$xvfb" ]; then kill "$xvfb" 2>/dev/null || true; fi
  rm -rf -- "$temp"
}
trap cleanup EXIT
trap 'exit 1' INT HUP TERM
python3 "$repo/examples/signal-rooms.py" "$project"
Xvfb "$DISPLAY" -screen 0 1440x900x24 -nolisten tcp >"$temp/x-display.log" 2>&1 &
xvfb=$!
cat > "$AMOEBA_BROWSER" <<'WRAPPER'
#!/bin/sh
echo "$$" > "$AMOEBA_TEST_PID"
exec "$AMOEBA_TEST_BROWSER" "--remote-debugging-port=$AMOEBA_TEST_PORT" "$@"
WRAPPER
chmod +x "$AMOEBA_BROWSER"
endpoint=http://127.0.0.1:$AMOEBA_TEST_PORT
daw() { "$repo/bin/amoeba" "$project" "$@"; }
daw play | grep 'PLAYING'
daw mix >"$temp/view.log" 2>&1 &
view=$!
node "$repo/tests/touch.js" "$endpoint" /dev/null || { cat "$temp/view.log"; exit 1; }
wait "$view"
view=
daw at | grep -E 'PLAYING.*\(B\)'
daw mix >"$temp/view.log" 2>&1 &
view=$!
node "$repo/tests/touch.js" "$endpoint" /dev/null reopen || { cat "$temp/view.log"; exit 1; }
kill -KILL "$(cat "$AMOEBA_TEST_PID")"
wait "$view"
view=
daw at | grep -E 'PLAYING.*\(B\)'
daw stop
sleep .25
daw at | grep -E 'STOPPED.*\(B\)'
daw session end
test ! -e "$temp/amoeba-daw-session.sexp"
echo 'PASS clean playback, touch detach/reconnect, browser crash, terminal stop.'
