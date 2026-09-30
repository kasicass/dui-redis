%% @doc Common Test suite for dui-redis.
%%
%% Covers config persistence, eredis option building and (when a local Redis
%% is reachable) a live connect/ping/disconnect round-trip.
-module(dui_redis_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    config_roundtrip/1,
    build_options/1,
    connect_live/1
]).

-spec all() -> [atom()].
all() ->
    [config_roundtrip, build_options, connect_live].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}].
init_per_suite(Config) ->
    Config.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok.

-spec init_per_testcase(atom(), [{atom(), term()}]) -> [{atom(), term()}].
init_per_testcase(_Case, Config) ->
    Config.

-spec end_per_testcase(atom(), [{atom(), term()}]) -> ok.
end_per_testcase(_Case, _Config) ->
    ok.

%% @doc Connections survive a save/load cycle without leaking `undefined'.
config_roundtrip(Config) ->
    Dir = ?config(priv_dir, Config),
    Path = filename:join(Dir, "config.json"),
    {ok, Conn} = dui_redis_config:add_connection(Path,
        #{name => <<"Local">>, host => <<"localhost">>, port => 6379}),
    Id = maps:get(id, Conn),
    {ok, [Saved]} = dui_redis_config:list_connections(Path),
    <<"Local">> = maps:get(name, Saved),
    6379 = maps:get(port, Saved),
    <<>> = maps:get(username, Saved),

    {ok, Bin} = file:read_file(Path),
    nomatch = binary:match(Bin, <<"\"undefined\"">>),

    {ok, _Updated} = dui_redis_config:update_connection(Path,
        Saved#{name => <<"Renamed">>}),
    {ok, [After]} = dui_redis_config:list_connections(Path),
    <<"Renamed">> = maps:get(name, After),

    ok = dui_redis_config:delete_connection(Path, Id),
    {ok, []} = dui_redis_config:list_connections(Path),

    %% A legacy file with the string "undefined" is repaired on load.
    RepairPath = filename:join(Dir, "repair.json"),
    RepairJson = <<"{\"connections\":[{\"id\":1,\"name\":\"x\",",
                   "\"host\":\"localhost\",\"port\":6379,",
                   "\"username\":\"undefined\",\"tls_config\":\"undefined\"}]}">>,
    ok = file:write_file(RepairPath, RepairJson),
    {ok, RepairCfg} = dui_redis_config:load(RepairPath),
    [Repaired] = maps:get(connections, RepairCfg),
    undefined = maps:get(username, Repaired),
    undefined = maps:get(tls_config, Repaired),
    ok.

%% @doc Empty credentials are omitted from eredis options.
build_options(_Config) ->
    Bare = dui_redis_client:build_options(
        #{host => <<"localhost">>, port => 6379, db => 3}),
    none = proplists:lookup(username, Bare),
    none = proplists:lookup(password, Bare),
    3 = proplists:get_value(database, Bare),

    Auth = dui_redis_client:build_options(
        #{host => <<"localhost">>, port => 6379, db => 0,
          username => <<"u">>, password => <<"p">>}),
    <<"u">> = proplists:get_value(username, Auth),
    <<"p">> = proplists:get_value(password, Auth),
    ok.

%% @doc Live connect/ping/disconnect against a local Redis (skipped if down).
connect_live(_Config) ->
    case redis_available() of
        false ->
            {skip, "no local Redis on 127.0.0.1:6379"};
        true ->
            {ok, _} = application:ensure_all_started(dui_redis),
            ok = dui_redis_client:connect(
                #{host => <<"localhost">>, port => 6379, db => 0}),
            {ok, <<"PONG">>} = dui_redis_client:ping(),
            true = dui_redis_client:is_connected(),
            ok = dui_redis_client:disconnect(),
            false = dui_redis_client:is_connected(),
            _ = application:stop(dui_redis),
            ok
    end.

-spec redis_available() -> boolean().
redis_available() ->
    case gen_tcp:connect("localhost", 6379, [], 500) of
        {ok, Socket} ->
            gen_tcp:close(Socket),
            true;
        _ ->
            false
    end.
