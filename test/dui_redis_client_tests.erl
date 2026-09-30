-module(dui_redis_client_tests).

-include_lib("eunit/include/eunit.hrl").

build_options_basic_test() ->
    Opts = dui_redis_client:build_options(
        #{host => <<"localhost">>, port => 6380, db => 2,
          username => <<"u">>, password => <<"p">>}),
    ?assertEqual("localhost", proplists:get_value(host, Opts)),
    ?assertEqual(6380, proplists:get_value(port, Opts)),
    ?assertEqual(2, proplists:get_value(database, Opts)),
    ?assertEqual(<<"u">>, proplists:get_value(username, Opts)),
    ?assertEqual(<<"p">>, proplists:get_value(password, Opts)),
    ?assertEqual(undefined, proplists:get_value(tls, Opts)).

build_options_omits_empty_credentials_test() ->
    Opts = dui_redis_client:build_options(
        #{host => <<"h">>, port => 6379, username => <<>>, password => undefined}),
    ?assertEqual(undefined, proplists:get_value(username, Opts)),
    ?assertEqual(undefined, proplists:get_value(password, Opts)).

build_options_tls_test() ->
    Opts = dui_redis_client:build_options(
        #{host => <<"h">>, port => 6379, use_tls => true,
          tls_config => #{ca_file => <<"/ca.pem">>, insecure_skip_verify => true}}),
    Tls = proplists:get_value(tls, Opts),
    ?assert(lists:member({cacertfile, "/ca.pem"}, Tls)),
    ?assert(lists:member({verify, verify_none}, Tls)).

no_client_is_safe_test() ->
    case whereis(dui_redis_client) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end,
    ?assertEqual({error, no_client}, dui_redis_client:connect(#{host => <<"h">>})),
    ?assertEqual({error, no_client}, dui_redis_client:test(#{host => <<"h">>})),
    ?assertEqual({error, no_client}, dui_redis_client:ping()).

live_connect_test_() ->
    case redis_available() of
        true -> {timeout, 30, fun live_connect/0};
        false -> []
    end.

live_connect() ->
    ensure_client(),
    Conn = #{host => <<"localhost">>, port => 6379, db => 0},
    ?assertEqual(ok, dui_redis_client:connect(Conn)),
    ?assertEqual(true, dui_redis_client:is_connected()),
    ?assertEqual({ok, <<"PONG">>}, dui_redis_client:ping()),
    ?assertEqual(ok, dui_redis_client:select_db(1)),
    ?assertEqual(ok, dui_redis_client:disconnect()),
    ?assertEqual(false, dui_redis_client:is_connected()),
    ?assertEqual({error, not_connected}, dui_redis_client:ping()).

live_test_via_ping_test_() ->
    case redis_available() of
        true -> {timeout, 30, fun live_test/0};
        false -> []
    end.

live_test() ->
    ensure_client(),
    ?assertMatch({ok, _Latency}, dui_redis_client:test(
        #{host => <<"localhost">>, port => 6379})),
    ?assertMatch({error, _}, dui_redis_client:test(
        #{host => <<"127.0.0.1">>, port => 6399})).

live_scan_and_preview_test_() ->
    case redis_available() of
        true -> {timeout, 30, fun live_scan_and_preview/0};
        false -> []
    end.

live_scan_and_preview() ->
    ensure_client(),
    ok = dui_redis_client:connect(#{host => <<"localhost">>, port => 6379, db => 0}),
    {ok, _} = dui_redis_client:q([<<"FLUSHDB">>]),
    {ok, _} = dui_redis_client:q([<<"SET">>, <<"m2:str">>, <<"hello">>]),
    {ok, _} = dui_redis_client:q([<<"RPUSH">>, <<"m2:list">>, <<"a">>, <<"b">>]),
    {ok, _} = dui_redis_client:q([<<"HSET">>, <<"m2:hash">>, <<"f">>, <<"v">>]),
    {ok, R} = dui_redis_client:scan_keys(<<"m2:*">>, 0, 100),
    Keys = maps:get(keys, R),
    ?assertEqual(3, length(Keys)),
    TypeMap = maps:from_list([{maps:get(key, K), maps:get(type, K)} || K <- Keys]),
    ?assertEqual(string, maps:get(<<"m2:str">>, TypeMap)),
    ?assertEqual(list, maps:get(<<"m2:list">>, TypeMap)),
    ?assertEqual(hash, maps:get(<<"m2:hash">>, TypeMap)),
    ?assertEqual(3, maps:get(total, R)),

    {ok, SV} = dui_redis_client:value_preview(<<"m2:str">>),
    ?assertEqual(string, maps:get(type, SV)),
    ?assertEqual(<<"hello">>, maps:get(text, SV)),
    {ok, LV} = dui_redis_client:value_preview(<<"m2:list">>),
    ?assertEqual([<<"a">>, <<"b">>], maps:get(items, LV)),
    {ok, HV} = dui_redis_client:value_preview(<<"m2:hash">>),
    ?assertEqual([{<<"f">>, <<"v">>}], maps:get(items, HV)),
    ok = dui_redis_client:disconnect().

live_write_ops_test_() ->
    case redis_available() of
        true -> {timeout, 30, fun live_write_ops/0};
        false -> []
    end.

live_write_ops() ->
    ensure_client(),
    ok = dui_redis_client:connect(#{host => <<"localhost">>, port => 6379, db => 0}),
    {ok, _} = dui_redis_client:q([<<"FLUSHDB">>]),
    {ok, _} = dui_redis_client:set_string(<<"m3:str">>, <<"v1">>, 0),
    {ok, D} = dui_redis_client:value_detail(<<"m3:str">>),
    ?assertEqual(<<"v1">>, maps:get(text, D)),
    {ok, _} = dui_redis_client:set_ttl(<<"m3:str">>, 100),
    ?assertMatch({ok, _}, dui_redis_client:key_ttl(<<"m3:str">>)),
    {ok, _} = dui_redis_client:rename_key(<<"m3:str">>, <<"m3:str2">>),
    {ok, _} = dui_redis_client:copy_key(<<"m3:str2">>, <<"m3:str3">>, false),
    {ok, _} = dui_redis_client:list_push(<<"m3:list">>, <<"a">>),
    {ok, _} = dui_redis_client:hash_set(<<"m3:hash">>, <<"f">>, <<"v">>),
    {ok, _} = dui_redis_client:set_add(<<"m3:set">>, <<"m">>),
    {ok, _} = dui_redis_client:zset_add(<<"m3:zset">>, 1.5, <<"m">>),
    {ok, _} = dui_redis_client:q([<<"XADD">>, <<"m3:stream">>, <<"*">>, <<"f">>, <<"v">>]),
    ?assertMatch({ok, _}, dui_redis_client:delete_key(<<"m3:str3">>)),
    {ok, V} = dui_redis_client:value_detail(<<"m3:list">>),
    ?assertEqual([<<"a">>], maps:get(items, V)),
    ok = dui_redis_client:disconnect().

%% ---------------------------------------------------------------------------

ensure_client() ->
    case whereis(dui_redis_client) of
        undefined ->
            {ok, Pid} = dui_redis_client:start_link(),
            Pid;
        Pid ->
            Pid
    end.

redis_available() ->
    case gen_tcp:connect("127.0.0.1", 6379, [binary, {active, false}], 300) of
        {ok, Sock} -> gen_tcp:close(Sock), true;
        {error, _} -> false
    end.
