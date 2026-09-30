# dui-redis

A Redis terminal UI manager built with [educkui](https://github.com/kasicass/educkui)
(pure Erlang, OTP 28+). It is a port of
[redis-tui](https://github.com/davidbudnick/redis-tui) to Erlang.

> See [`../dui-redis-plan.md`](../dui-redis-plan.md) for the full implementation
> plan and the educkui improvements it depends on.

## Status

**M1 — connection management** (done). Currently implemented:

- educkui runtime integration (root Elm component, help overlay, status bar)
- CLI parsing via OTP `argparse` (redis-cli style flags)
- JSON configuration at `~/.config/dui-redis/config.json` (secrets stripped)
- connection manager: list, add/edit form, test connection, delete confirmation
- connect/disconnect against Redis via `eredis`; auto-connect from `--host`
- proof-of-life for runtime features: async command results, 1 Hz interval,
  resize delivery

Keys/browse/edit/monitor features arrive in later milestones (M2+).

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
