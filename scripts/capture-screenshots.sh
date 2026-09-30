#!/usr/bin/env bash
# Regenerate the README screenshots (docs/screenshots/*.svg).
#
# Requirements: tmux, python3, a Redis on localhost (e.g. `docker compose up -d`).
# The script seeds throwaway data, drives the TUI in a detached tmux session and
# converts each screen to SVG via scripts/ansi2svg.py.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=docs/screenshots
SESSION=dui-shots
mkdir -p "$OUT"

echo "==> seeding demo data"
redis-cli flushdb >/dev/null
redis-cli set user:1001:name "Alice" >/dev/null
redis-cli expire user:1001:name 3600 >/dev/null
redis-cli set session:abc123 "hello world" >/dev/null
redis-cli rpush queue:tasks "build" "test" "deploy" >/dev/null
redis-cli sadd set:tags "a" "b" "c" >/dev/null
redis-cli zadd zset:scores 10 "p1" 20 "p2" 30 "p3" >/dev/null
redis-cli hset hash:user:42 name "Bob" age "30" >/dev/null
redis-cli set cfg:feature '{"enabled":true,"limit":5}' >/dev/null

tmux kill-session -t "$SESSION" 2>/dev/null || true
trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true' EXIT

echo "==> starting dui-redis"
tmux new-session -d -s "$SESSION" -x 120 -y 34 \
    "TERM=xterm-256color ./scripts/run.sh --host localhost; sleep 300"
sleep 7

shot() {
    tmux capture-pane -t "$SESSION" -e -p > "/tmp/dui-$1.ansi"
    python3 scripts/ansi2svg.py "/tmp/dui-$1.ansi" "$OUT/$1.svg"
    echo "    $OUT/$1.svg"
}

shot keys
tmux send-keys -t "$SESSION" Enter; sleep 2
shot detail
tmux send-keys -t "$SESSION" Escape; sleep 1
tmux send-keys -t "$SESSION" '?'; sleep 1
shot help
tmux send-keys -t "$SESSION" '?'; sleep 1
tmux send-keys -t "$SESSION" 'm'; sleep 2
shot metrics
tmux send-keys -t "$SESSION" Escape; sleep 1
tmux send-keys -t "$SESSION" 'M'; sleep 2
shot memory
tmux send-keys -t "$SESSION" Escape; sleep 1
tmux send-keys -t "$SESSION" Escape; sleep 2
shot connections

echo "==> done"
