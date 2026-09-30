-module(dui_redis_config_tests).

-include_lib("eunit/include/eunit.hrl").

defaults_test() ->
    D = dui_redis_config:defaults(),
    ?assertEqual([], maps:get(connections, D)),
    ?assertEqual(20, maps:get(max_recent_keys, D)),
    ?assertEqual(50, maps:get(max_value_history, D)).

load_missing_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "missing.json"),
    ?assertEqual({ok, dui_redis_config:defaults()}, dui_redis_config:load(Path)),
    cleanup(Dir).

roundtrip_persists_fields_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    Config = #{
        connections => [#{id => 1, name => <<"Local">>, host => <<"localhost">>,
                          port => 6379, username => <<"default">>,
                          password => <<"secret">>, db => 3,
                          use_cluster => false, use_tls => false}],
        favorites => [],
        recent_keys => [],
        templates => [],
        tree_separator => <<":">>,
        max_recent_keys => 20,
        max_value_history => 50,
        watch_interval_ms => 1000
    },
    ok = dui_redis_config:save(Path, Config),
    {ok, Loaded} = dui_redis_config:load(Path),
    [Conn] = maps:get(connections, Loaded),
    ?assertEqual(<<"Local">>, maps:get(name, Conn)),
    ?assertEqual(<<"localhost">>, maps:get(host, Conn)),
    ?assertEqual(3, maps:get(db, Conn)),
    ?assertEqual(<<":">>, maps:get(tree_separator, Loaded)),
    cleanup(Dir).

password_stripping_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    Config = #{connections => [#{name => <<"C">>, host => <<"h">>,
                                 password => <<"topsecret">>}]},
    ok = dui_redis_config:save(Path, Config),
    {ok, Bin} = file:read_file(Path),
    ?assertEqual(nomatch, binary:match(Bin, <<"topsecret">>)),
    {ok, Loaded} = dui_redis_config:load(Path),
    [Conn] = maps:get(connections, Loaded),
    ?assertEqual(<<>>, maps:get(password, Conn)),
    cleanup(Dir).

strip_secrets_test() ->
    Config = #{connections => [#{password => <<"x">>, host => <<"h">>}]},
    Stripped = dui_redis_config:strip_secrets(Config),
    [Conn] = maps:get(connections, Stripped),
    ?assertNot(maps:is_key(password, Conn)).

invalid_json_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    ok = file:write_file(Path, <<"{not json">>),
    ?assertMatch({error, {invalid_config, _}}, dui_redis_config:load(Path)),
    cleanup(Dir).

%% ---------------------------------------------------------------------------

mk_tmp() ->
    Dir = filename:join("/tmp", "dui_redis_test_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

cleanup(Dir) ->
    _ = file:del_dir_r(Dir),
    ok.
