%% @doc Command factories.
%%
%% Wraps side effects in `{exec, Fun}' commands. Results are delivered back to
%% the issuing component as `command_result' events (educkui E0); the root
%% component handles the tagged result tuples in `update/2'.
-module(dui_redis_cmd).

-include("dui_redis.hrl").

-export([
    load_config/1,
    load_connections/1,
    add_connection/2,
    update_connection/2,
    delete_connection/2,
    connect/1,
    disconnect/0,
    test_connection/1,
    load_keys/4,
    load_preview/2,
    load_detail/2,
    write/2,
    delete_key/1,
    flush_db/0,
    load_favorites/1,
    add_favorite/3,
    remove_favorite/2,
    load_recent/1,
    add_recent/3,
    clear_recent/1,
    load_templates/1,
    regex_search/2,
    fuzzy_search/2,
    search_by_value/3,
    compare_keys/2,
    json_get_path/2,
    load_server_info/1,
    load_slow_log/2,
    load_clients/1,
    load_memory_stats/1,
    load_live_metrics/1,
    load_expiring/2,
    switch_db/2,
    debounce_filter/3
]).

%% @doc Asynchronously loads the whole config file.
-spec load_config(#dui_state{}) -> educkui_command:command().
load_config(State) ->
    Path = config_path(State),
    educkui_command:exec(fun() ->
        {config_loaded, safe(fun() -> dui_redis_config:load(Path) end)}
    end).

%% @doc Asynchronously loads the saved connections.
-spec load_connections(#dui_state{}) -> educkui_command:command().
load_connections(State) ->
    Path = config_path(State),
    educkui_command:exec(fun() ->
        {connections_loaded, safe(fun() -> dui_redis_config:list_connections(Path) end)}
    end).

%% @doc Adds a connection.
-spec add_connection(#dui_state{}, map()) -> educkui_command:command().
add_connection(State, Conn) ->
    Path = config_path(State),
    educkui_command:exec(fun() ->
        {connection_added, safe(fun() -> dui_redis_config:add_connection(Path, Conn) end)}
    end).

%% @doc Updates a connection.
-spec update_connection(#dui_state{}, map()) -> educkui_command:command().
update_connection(State, Conn) ->
    Path = config_path(State),
    educkui_command:exec(fun() ->
        {connection_updated, safe(fun() -> dui_redis_config:update_connection(Path, Conn) end)}
    end).

%% @doc Deletes a connection by id.
-spec delete_connection(#dui_state{}, integer()) -> educkui_command:command().
delete_connection(State, Id) ->
    Path = config_path(State),
    educkui_command:exec(fun() ->
        {connection_deleted, Id, safe(fun() -> dui_redis_config:delete_connection(Path, Id) end)}
    end).

%% @doc Connects to Redis.
-spec connect(map()) -> educkui_command:command().
connect(Conn) ->
    educkui_command:exec(fun() ->
        {connected, safe(fun() -> dui_redis_client:connect(Conn) end)}
    end).

%% @doc Disconnects from Redis.
-spec disconnect() -> educkui_command:command().
disconnect() ->
    educkui_command:exec(fun() ->
        {disconnected, safe(fun() -> dui_redis_client:disconnect() end)}
    end).

%% @doc Tests a connection without changing the active one.
-spec test_connection(map()) -> educkui_command:command().
test_connection(Conn) ->
    educkui_command:exec(fun() ->
        {connection_tested, safe(fun() -> dui_redis_client:test(Conn) end)}
    end).

%% @doc Scans keys with the given pattern and cursor.
-spec load_keys(#dui_state{}, binary(), integer(), integer()) -> educkui_command:command().
load_keys(_State, Pattern, Cursor, Count) ->
    educkui_command:exec(fun() ->
        {keys_loaded, Cursor,
         safe(fun() -> dui_redis_client:scan_keys(Pattern, Cursor, Count) end)}
    end).

%% @doc Loads a bounded value preview for `Key'.
-spec load_preview(#dui_state{}, binary()) -> educkui_command:command().
load_preview(_State, Key) ->
    educkui_command:exec(fun() ->
        {preview_loaded, Key, safe(fun() -> dui_redis_client:value_preview(Key) end)}
    end).

%% @doc Loads the larger detail value for `Key'.
-spec load_detail(#dui_state{}, binary()) -> educkui_command:command().
load_detail(_State, Key) ->
    educkui_command:exec(fun() ->
        {detail_loaded, Key, safe(fun() -> dui_redis_client:value_detail(Key) end)}
    end).

%% @doc Runs a side-effecting write fun, tagging the result with `Tag'.
-spec write(atom(), fun(() -> term())) -> educkui_command:command().
write(Tag, Fun) when is_function(Fun, 0) ->
    educkui_command:exec(fun() -> {Tag, safe(Fun)} end).

%% @doc Deletes `Key', echoing the key back for state updates.
-spec delete_key(binary()) -> educkui_command:command().
delete_key(Key) ->
    educkui_command:exec(fun() ->
        {key_deleted, Key, safe(fun() -> dui_redis_client:delete_key(Key) end)}
    end).

%% @doc Flushes the current database.
-spec flush_db() -> educkui_command:command().
flush_db() ->
    educkui_command:exec(fun() ->
        {db_flushed, safe(fun() -> dui_redis_client:flush_db() end)}
    end).

%% -- favorites / recent / templates -----------------------------------------

-spec load_favorites(#dui_state{}) -> educkui_command:command().
load_favorites(State) ->
    Path = config_path(State),
    Id = conn_id(State),
    educkui_command:exec(fun() ->
        {favorites_loaded, safe(fun() -> dui_redis_config:list_favorites(Path, Id) end)}
    end).

-spec add_favorite(#dui_state{}, binary(), binary()) -> educkui_command:command().
add_favorite(State, Key, Label) ->
    Path = config_path(State),
    Id = conn_id(State),
    educkui_command:exec(fun() ->
        {favorite_added, Key, safe(fun() -> dui_redis_config:add_favorite(Path, Id, Key, Label) end)}
    end).

-spec remove_favorite(#dui_state{}, binary()) -> educkui_command:command().
remove_favorite(State, Key) ->
    Path = config_path(State),
    Id = conn_id(State),
    educkui_command:exec(fun() ->
        {favorite_removed, Key, safe(fun() -> dui_redis_config:remove_favorite(Path, Id, Key) end)}
    end).

-spec load_recent(#dui_state{}) -> educkui_command:command().
load_recent(State) ->
    Path = config_path(State),
    Id = conn_id(State),
    educkui_command:exec(fun() ->
        {recent_loaded, safe(fun() -> dui_redis_config:list_recent(Path, Id) end)}
    end).

-spec add_recent(#dui_state{}, binary(), binary()) -> educkui_command:command().
add_recent(State, Key, Type) ->
    Path = config_path(State),
    Id = conn_id(State),
    educkui_command:exec(fun() ->
        {recent_added, safe(fun() -> dui_redis_config:add_recent(Path, Id, Key, Type) end)}
    end).

-spec clear_recent(#dui_state{}) -> educkui_command:command().
clear_recent(State) ->
    Path = config_path(State),
    Id = conn_id(State),
    educkui_command:exec(fun() ->
        {recent_cleared, safe(fun() -> dui_redis_config:clear_recent(Path, Id) end)}
    end).

-spec load_templates(#dui_state{}) -> educkui_command:command().
load_templates(State) ->
    Path = config_path(State),
    educkui_command:exec(fun() ->
        {templates_loaded, safe(fun() -> dui_redis_config:list_templates(Path) end)}
    end).

%% -- search -----------------------------------------------------------------

-spec regex_search(binary(), pos_integer()) -> educkui_command:command().
regex_search(Pattern, Max) ->
    educkui_command:exec(fun() ->
        {search_results, {<<"Regex">>, regex},
         safe(fun() -> dui_redis_client:scan_regex(Pattern, Max) end)}
    end).

-spec fuzzy_search(binary(), pos_integer()) -> educkui_command:command().
fuzzy_search(Term, Max) ->
    educkui_command:exec(fun() ->
        {search_results, {<<"Fuzzy">>, fuzzy},
         safe(fun() -> dui_redis_client:fuzzy_search(Term, Max) end)}
    end).

-spec search_by_value(binary(), binary(), pos_integer()) -> educkui_command:command().
search_by_value(Pattern, Search, Max) ->
    educkui_command:exec(fun() ->
        {search_results, {<<"Value">>, value},
         safe(fun() -> dui_redis_client:search_by_value(Pattern, Search, Max) end)}
    end).

-spec compare_keys(binary(), binary()) -> educkui_command:command().
compare_keys(Key1, Key2) ->
    educkui_command:exec(fun() ->
        {compare_result, safe(fun() -> dui_redis_client:compare_keys(Key1, Key2) end)}
    end).

-spec json_get_path(binary(), binary()) -> educkui_command:command().
json_get_path(Key, Path) ->
    educkui_command:exec(fun() ->
        {json_result, safe(fun() -> dui_redis_client:json_get_path(Key, Path) end)}
    end).

-spec conn_id(#dui_state{}) -> integer().
conn_id(State) ->
    case dui_redis_state:current_conn(State) of
        undefined -> 0;
        Conn -> maps:get(id, Conn, 0)
    end.

%% -- monitoring -------------------------------------------------------------

-spec load_server_info(#dui_state{}) -> educkui_command:command().
load_server_info(_State) ->
    educkui_command:exec(fun() ->
        {server_info_loaded, safe(fun() -> dui_redis_client:server_info() end)}
    end).

-spec load_slow_log(#dui_state{}, pos_integer()) -> educkui_command:command().
load_slow_log(_State, N) ->
    educkui_command:exec(fun() ->
        {slow_log_loaded, safe(fun() -> dui_redis_client:slow_log(N) end)}
    end).

-spec load_clients(#dui_state{}) -> educkui_command:command().
load_clients(_State) ->
    educkui_command:exec(fun() ->
        {clients_loaded, safe(fun() -> dui_redis_client:client_list() end)}
    end).

-spec load_memory_stats(#dui_state{}) -> educkui_command:command().
load_memory_stats(_State) ->
    educkui_command:exec(fun() ->
        {memory_stats_loaded, safe(fun() -> dui_redis_client:memory_stats() end)}
    end).

-spec load_live_metrics(#dui_state{}) -> educkui_command:command().
load_live_metrics(_State) ->
    educkui_command:exec(fun() ->
        {live_metrics_loaded, safe(fun() -> dui_redis_client:live_metrics() end)}
    end).

-spec load_expiring(#dui_state{}, pos_integer()) -> educkui_command:command().
load_expiring(_State, Threshold) ->
    educkui_command:exec(fun() ->
        {expiring_loaded, safe(fun() -> dui_redis_client:expiring_keys(Threshold) end)}
    end).

%% @doc Switches the active database.
-spec switch_db(#dui_state{}, integer()) -> educkui_command:command().
switch_db(_State, Db) ->
    educkui_command:exec(fun() ->
        {db_switched, Db, safe(fun() -> dui_redis_client:select_db(Db) end)}
    end).

%% @doc Debounces a live filter: sleeps briefly then reports back with `Seq'.
-spec debounce_filter(#dui_state{}, binary(), integer()) -> educkui_command:command().
debounce_filter(_State, Pattern, Seq) ->
    educkui_command:exec(fun() ->
        timer:sleep(250),
        {filter_debounced, Seq, Pattern}
    end).

%% ---------------------------------------------------------------------------

-spec config_path(#dui_state{}) -> string().
config_path(State) ->
    case dui_redis_state:config_path(State) of
        undefined -> dui_redis_config:path();
        Path -> Path
    end.

%% @doc Runs a side-effecting fun, converting exceptions to error tuples.
-spec safe(fun(() -> T)) -> T | {error, term()}.
safe(Fun) ->
    try Fun()
    catch
        Class:Reason:Stack -> {error, {Class, Reason, Stack}}
    end.
