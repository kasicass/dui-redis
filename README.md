# dui-redis

A Redis terminal UI manager built with [educkui](https://github.com/kasicass/educkui)
(pure Erlang, OTP 28+). It is a port of
[redis-tui](https://github.com/davidbudnick/redis-tui) to Erlang.

> See [`../dui-redis-plan.md`](../dui-redis-plan.md) for the full implementation
> plan and the educkui improvements it depends on.

## Status

**M7 — advanced display and security** (done; some UI deferred). All planned
milestones M0–M7 are implemented. Highlights:

- connection manager, key browser, detail/edit, search/favorites/tree,
  monitoring, ops/cluster (see git history for the per-milestone breakdown)
- schema-less protobuf and Snappy/S2 decoding of binary string values
- JSON syntax highlighting in the detail view
- HashiCorp Vault credential resolution (KV v1/v2, dot selectors)
- TLS via CLI/config; OSC 52 clipboard copy (`y`)
- 143 EUnit tests; `./scripts/ci.sh` (compile → eunit → xref → dialyzer → edoc)

Deferred: live Pub/Sub subscription stream and Keyspace Events; cluster-mode
connection; Key Bindings customization UI; TLS certificate form.

See [`../dui-redis-plan.md`](../dui-redis-plan.md) for the full plan.

## Requirements

- Erlang/OTP 28+
- rebar3
- A terminal supporting raw mode

Dependencies are declared in `rebar.config`:

- `educkui` — git dep (`github.com/kasicass/educkui`)
- `eredis` — hex

## Build and run

> **Local dev note**: until the educkui cursor-optimizer fix (commit `9818028`) is on
> `github.com/kasicass/educkui`, this repo uses `_checkouts/educkui` (a gitignored
> symlink to `../tui/educkui`) so the local educkui is used. Once pushed, remove
> `_checkouts/` and run `rebar3 upgrade educkui` to refresh `rebar.lock`.

```bash
rebar3 compile

# from a shell
rebar3 shell
1> dui_redis:run([]).

# or as an escript (see scripts/)
```

Quick connect:

```bash
rebar3 shell
1> dui_redis:run(["--host", "localhost", "-p", "6379", "-n", "0"]).
```

Press `?` for help, `q` to quit.

## CLI flags

| Flag | Short | Description | Default |
|---|---|---|---|
| `--host` | `-h` | Redis host | |
| `--port` | `-p` | Redis port | 6379 |
| `--password` | `-a` | Redis password | |
| `--user` | | Redis ACL username | |
| `--db` | `-n` | Database number | 0 |
| `--name` | | Connection display name | `host:port` |
| `--cluster` | | Enable cluster mode | false |
| `--tls` | | Enable TLS/SSL | false |
| `--tls-cert` / `--tls-key` / `--tls-ca` | | TLS files | |
| `--tls-skip-verify` | | Skip TLS verification | false |
| `--scan-size` | | SCAN COUNT hint | 1000 |
| `--include-types` | | Fetch key types during scan | true |
| `--config` | | Config file path | `~/.config/dui-redis/config.json` |
| `--version` | | Print version and exit | |

## Layout

```
src/
  dui_redis.erl          entry point (main/1, run/1)
  dui_redis_cli.erl      argparse-based CLI
  dui_redis_root.erl     root educkui component (init/event_to_msg/update/view)
  dui_redis_state.erl    state record + pure transitions
  dui_redis_cmd.erl      async command factories
  dui_redis_config.erl   JSON persistence
  dui_redis_theme.erl    styles
  dui_redis_fmt.erl      formatting helpers
test/                    EUnit tests
include/dui_redis.hrl    shared record/macros
```

## Test

```bash
rebar3 eunit
./scripts/ci.sh   # compile -> eunit -> xref -> dialyzer -> edoc
```
