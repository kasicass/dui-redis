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

add_list_update_delete_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    ?assertEqual({ok, []}, dui_redis_config:list_connections(Path)),
    {ok, Added} = dui_redis_config:add_connection(Path,
        #{name => <<"Local">>, host => <<"localhost">>, port => 6379, db => 0}),
    ?assertEqual(1, maps:get(id, Added)),
    ?assertNotEqual(undefined, maps:get(created_at, Added)),
    {ok, Conns} = dui_redis_config:list_connections(Path),
    ?assertEqual(1, length(Conns)),
    ?assertEqual(<<"Local">>, maps:get(name, hd(Conns))),

    %% second add gets the next id
    {ok, Added2} = dui_redis_config:add_connection(Path,
        #{name => <<"Prod">>, host => <<"prod">>, port => 6380}),
    ?assertEqual(2, maps:get(id, Added2)),

    %% update preserves id and created_at
    {ok, Updated} = dui_redis_config:update_connection(Path,
        Added#{name => <<"Local Renamed">>}),
    ?assertEqual(1, maps:get(id, Updated)),
    ?assertEqual(maps:get(created_at, Added), maps:get(created_at, Updated)),
    {ok, Conns2} = dui_redis_config:list_connections(Path),
    Names = [maps:get(name, C) || C <- Conns2],
    ?assert(lists:member(<<"Local Renamed">>, Names)),

    %% delete
    ok = dui_redis_config:delete_connection(Path, 1),
    {ok, Conns3} = dui_redis_config:list_connections(Path),
    ?assertEqual(1, length(Conns3)),
    ?assertEqual(<<"Prod">>, maps:get(name, hd(Conns3))),
    ?assertEqual({error, not_found}, dui_redis_config:delete_connection(Path, 99)),
    ?assertEqual({error, not_found}, dui_redis_config:update_connection(Path,
        #{id => 99, name => <<"x">>})),
    cleanup(Dir).

add_strips_password_on_disk_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    {ok, _} = dui_redis_config:add_connection(Path,
        #{name => <<"C">>, host => <<"h">>, password => <<"topsecret">>}),
    {ok, Bin} = file:read_file(Path),
    ?assertEqual(nomatch, binary:match(Bin, <<"topsecret">>)),
    cleanup(Dir).

binary_path_test() ->
    %% CLI passes the config path as a binary; CRUD must accept it.
    Dir = mk_tmp(),
    Path = list_to_binary(filename:join(Dir, "config.json")),
    {ok, Added} = dui_redis_config:add_connection(Path,
        #{name => <<"Bin">>, host => <<"localhost">>}),
    ?assertEqual(1, maps:get(id, Added)),
    {ok, Conns} = dui_redis_config:list_connections(Path),
    ?assertEqual(1, length(Conns)),
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

favorites_crud_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    ?assertEqual({ok, []}, dui_redis_config:list_favorites(Path, 1)),
    {ok, Fav} = dui_redis_config:add_favorite(Path, 1, <<"k">>, <<"Label">>),
    ?assertEqual(<<"k">>, maps:get(key, Fav)),
    {ok, Favs} = dui_redis_config:list_favorites(Path, 1),
    ?assertEqual(1, length(Favs)),
    ?assert(dui_redis_config:is_favorite(Path, 1, <<"k">>)),
    %% idempotent
    {ok, _} = dui_redis_config:add_favorite(Path, 1, <<"k">>, <<"Label">>),
    {ok, Favs1} = dui_redis_config:list_favorites(Path, 1),
    ?assertEqual(1, length(Favs1)),
    ok = dui_redis_config:remove_favorite(Path, 1, <<"k">>),
    ?assertNot(dui_redis_config:is_favorite(Path, 1, <<"k">>)),
    cleanup(Dir).

recent_keys_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    ok = dui_redis_config:add_recent(Path, 1, <<"a">>, <<"string">>),
    ok = dui_redis_config:add_recent(Path, 1, <<"b">>, <<"list">>),
    ok = dui_redis_config:add_recent(Path, 1, <<"a">>, <<"string">>),
    {ok, Recent} = dui_redis_config:list_recent(Path, 1),
    ?assertEqual([<<"a">>, <<"b">>], [maps:get(key, R) || R <- Recent]),
    ok = dui_redis_config:clear_recent(Path, 1),
    ?assertEqual({ok, []}, dui_redis_config:list_recent(Path, 1)),
    cleanup(Dir).

default_templates_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    {ok, Templates} = dui_redis_config:list_templates(Path),
    ?assert(length(Templates) >= 5),
    Names = [maps:get(name, T) || T <- Templates],
    ?assert(lists:member(<<"Session">>, Names)),
    cleanup(Dir).
