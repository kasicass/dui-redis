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
    test_connection/1
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
