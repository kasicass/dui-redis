#!/usr/bin/env bash
# Build and run dui-redis, passing all arguments through to the CLI.
#
# Usage:
#   ./scripts/run.sh                          # interactive connection manager
#   ./scripts/run.sh --host localhost         # quick connect
#   ./scripts/run.sh -h redis.example.com -p 6380 -a secret -n 2
#   ./scripts/run.sh --host localhost --config /tmp/dui.json
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> compiling" >&2
rebar3 compile >/dev/null

PA=$(ls -d _build/default/lib/*/ebin 2>/dev/null | sed 's/^/-pa /' | tr '\n' ' ')

exec erl $PA -noshell \
    -eval 'Args = init:get_plain_arguments(), dui_redis:run(Args), init:stop().' \
    -extra "$@"
