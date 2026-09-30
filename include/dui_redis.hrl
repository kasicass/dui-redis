%% -*- erlang -*-
-ifndef(DUI_REDIS_HRL).
-define(DUI_REDIS_HRL, true).

%% Application version (also mirrored in dui_redis.erl).
-define(DUI_REDIS_VERSION, "0.1.0").

%% Root component state. All screens share this single state, mirroring
%% redis-tui's Model.
-record(dui_state, {
    runtime :: pid() | undefined,
    cli = #{} :: map(),
    config_path :: string() | undefined,
    screen = connections :: atom(),
    prev_screen :: atom() | undefined,
    size = {24, 80} :: {pos_integer(), pos_integer()},
    connections = [] :: [map()],
    selected = 0 :: non_neg_integer(),
    current_conn :: map() | undefined,
    editing_conn :: map() | undefined,
    conn_form = #{} :: map(),
    confirm :: term() | undefined,
    test_result :: binary() | undefined,
    connection_error :: binary() | undefined,
    connected = false :: boolean(),
    status :: {info | error, binary()} | undefined,
    loading = false :: boolean(),
    show_help = false :: boolean(),
    ticks = 0 :: non_neg_integer()
}).

-endif.
