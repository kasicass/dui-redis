#!/usr/bin/env bash
# dui-redis CI: compile -> eunit -> common test -> xref -> dialyzer -> edoc.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> compile"
rebar3 compile

echo "==> eunit"
rebar3 eunit

echo "==> ct"
rebar3 ct

echo "==> xref"
rebar3 xref

echo "==> dialyzer"
rebar3 dialyzer

echo "==> edoc"
rebar3 edoc

echo "==> done"
