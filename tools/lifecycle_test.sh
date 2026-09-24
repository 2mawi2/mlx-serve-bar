#!/bin/zsh
# End-to-end lifecycle test against a mock server (never touches the real mlx-serve).
set -eu
cd "$(dirname "$0")/.."

./build.sh

TDIR=/tmp/mlxbar-test
# clean leftovers from a previously failed run (never matches the app installed in ~/Applications)
.build/release/mlxbar ctl --config "$TDIR/cfg.json" quit 2>/dev/null || true
pkill -f 'mock_metrics_server.py 11999' 2>/dev/null || true
pkill -f '\.build/release/mlxbar$' 2>/dev/null || true
rm -rf "$TDIR"; mkdir -p "$TDIR"
cat > "$TDIR/cfg.json" <<EOF
{
  "bin": "$(pwd)/tools/mockbin",
  "args": ["11999"],
  "host": "127.0.0.1",
  "port": 11999
}
EOF
BIN=.build/release/mlxbar
CTL=($BIN ctl --config $TDIR/cfg.json)

fail() { echo "TEST FAIL: $1"; pkill -f 'mock_metrics_server.py 11999' 2>/dev/null || true; kill $GUI 2>/dev/null || true; exit 1 }

# start GUI instance against test config
MLX_BAR_CONFIG="$TDIR/cfg.json" "$BIN" &
GUI=$!
trap 'kill $GUI 2>/dev/null || true' EXIT

# wait for rpc socket
for i in {1..50}; do [[ -S "$TDIR/cfg.rpc.sock" ]] && break; sleep 0.1; done
[[ -S "$TDIR/cfg.rpc.sock" ]] || fail "rpc socket never appeared"
sleep 0.5

echo "→ ping"
$CTL ping | grep -q '"pong"' || fail "ping"

echo "→ initial status (mock not running yet)"
S=$($CTL status) || true
echo "$S"
echo "$S" | grep -q '"state":"stopped"' || fail "expected stopped, got: $S"

echo "→ start"
$CTL start | grep -q '"ok"' || fail "start"
for i in {1..100}; do
  $CTL status | grep -q '"serving":true' && break
  sleep 0.2
done
S=$($CTL status)
echo "$S" | grep -q '"serving":true' || fail "never became serving: $S"
echo "$S" | grep -q '"state":"running"' || fail "state not running"

echo "→ metrics flowing via ctl"
$CTL status | grep -q '"live_tokens":[1-9]' || fail "live_tokens did not advance"

echo "→ mock reachable on port"
curl -sf http://127.0.0.1:11999/health > /dev/null || fail "mock not answering"

echo "→ stop"
$CTL stop | grep -q '"ok"' || fail "stop"
for i in {1..100}; do
  $CTL status | grep -q '"serving":false' && break
  sleep 0.2
done
S=$($CTL status)
echo "$S" | grep -q '"serving":false' || fail "still serving after stop: $S"
echo "$S" | grep -q '"state":"stopped"' || fail "state not stopped"
curl -sf http://127.0.0.1:11999/health > /dev/null 2>&1 && fail "mock survived stop" || true

echo "→ quit"
$CTL quit | grep -q '"bye"' || fail "quit resp"
for i in {1..50}; do kill -0 $GUI 2>/dev/null || break; sleep 0.1; done
kill -0 $GUI 2>/dev/null && fail "gui still alive after quit" || true
trap - EXIT

echo "ALL LIFECYCLE TESTS PASS"
