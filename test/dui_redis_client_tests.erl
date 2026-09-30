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

live_search_test_() ->
    case redis_available() of
        true -> {timeout, 30, fun live_search/0};
        false -> []
    end.

live_search() ->
    ensure_client(),
    ok = dui_redis_client:connect(#{host => <<"localhost">>, port => 6379, db => 0}),
    {ok, _} = dui_redis_client:q([<<"FLUSHDB">>]),
    {ok, _} = dui_redis_client:set_string(<<"m4:user:1">>, <<"needle here">>, 0),
    {ok, _} = dui_redis_client:set_string(<<"m4:user:2">>, <<"nothing">>, 0),
    {ok, _} = dui_redis_client:set_string(<<"m4:other">>, <<"needle too">>, 0),
    {ok, R1} = dui_redis_client:scan_regex(<<"^m4:user">>, 100),
    ?assertEqual([<<"m4:user:1">>, <<"m4:user:2">>],
                 lists:sort([maps:get(key, K) || K <- R1])),
    {ok, R2} = dui_redis_client:fuzzy_search(<<"user">>, 100),
    ?assert(length(R2) >= 1),
    {ok, R3} = dui_redis_client:search_by_value(<<"m4:*">>, <<"needle">>, 100),
    ?assertEqual([<<"m4:other">>, <<"m4:user:1">>],
                 lists:sort([maps:get(key, K) || K <- R3])),
    {ok, {_V1, _V2, Diff}} = dui_redis_client:compare_keys(<<"m4:user:1">>, <<"m4:user:2">>),
    ?assert(is_binary(Diff)),
    ok = dui_redis_client:disconnect().

live_monitoring_test_() ->
    case redis_available() of
        true -> {timeout, 40, fun live_monitoring/0};
        false -> []
    end.

live_monitoring() ->
    ensure_client(),
    ok = dui_redis_client:connect(#{host => <<"localhost">>, port => 6379, db => 0}),
    {ok, _} = dui_redis_client:q([<<"FLUSHDB">>]),
    {ok, _} = dui_redis_client:set_string(<<"m5:short">>, <<"v">>, 60),
    {ok, _} = dui_redis_client:set_string(<<"m5:long">>, <<"v">>, 100000),
    {ok, Info} = dui_redis_client:server_info(),
    ?assert(is_binary(maps:get(version, Info, <<>>))),
    ?assertEqual(<<"2">>, maps:get(total_keys, Info, <<>>)),
    {ok, Mem} = dui_redis_client:memory_stats(),
    ?assert(maps:is_key(used, Mem)),
    {ok, Metrics} = dui_redis_client:live_metrics(),
    ?assert(is_integer(maps:get(ops, Metrics, -1))),
    {ok, Clients} = dui_redis_client:client_list(),
    ?assert(length(Clients) >= 1),
    {ok, _Slow} = dui_redis_client:slow_log(10),
    {ok, Expiring} = dui_redis_client:expiring_keys(300),
    Keys = [maps:get(key, K) || K <- Expiring],
    ?assert(lists:member(<<"m5:short">>, Keys)),
    ?assertNot(lists:member(<<"m5:long">>, Keys)),
    ok = dui_redis_client:disconnect().

live_ops_test_() ->
    case redis_available() of
        true -> {timeout, 40, fun live_ops/0};
        false -> []
    end.

live_ops() ->
    ensure_client(),
    ok = dui_redis_client:connect(#{host => <<"localhost">>, port => 6379, db => 0}),
    {ok, _} = dui_redis_client:q([<<"FLUSHDB">>]),
    {ok, _} = dui_redis_client:set_string(<<"m6:a">>, <<"v">>, 0),
    {ok, _} = dui_redis_client:set_string(<<"m6:b">>, <<"v">>, 0),
    ?assertEqual({ok, 0}, dui_redis_client:publish(<<"m6:chan">>, <<"hi">>)),
    {ok, _Channels} = dui_redis_client:pubsub_channels(<<"*">>),
    {ok, Config} = dui_redis_client:config_get(<<"maxmemory">>),
    ?assert(maps:is_key(<<"maxmemory">>, Config)),
    ok = dui_redis_client:config_set(<<"maxmemory">>, <<"0">>),
    ?assertEqual({ok, <<"2">>}, dui_redis_client:eval_script(<<"return 1+1">>)),
    {ok, Deleted} = dui_redis_client:bulk_delete(<<"m6:*">>),
    ?assertEqual(2, Deleted),
    %% batch TTL
    {ok, _} = dui_redis_client:set_string(<<"m6t:a">>, <<"v">>, 0),
    {ok, _} = dui_redis_client:set_string(<<"m6t:b">>, <<"v">>, 0),
    {ok, TtlCount} = dui_redis_client:batch_set_ttl(<<"m6t:*">>, 100),
    ?assertEqual(2, TtlCount),
    %% export / import round-trip
    Dir = filename:join("/tmp", "dui_m6_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    File = filename:join(Dir, "export.json"),
    {ok, Exported} = dui_redis_client:export_to_file(<<"m6t:*">>, File),
    ?assert(Exported >= 1),
    {ok, _} = dui_redis_client:q([<<"FLUSHDB">>]),
    {ok, Imported} = dui_redis_client:import_from_file(File),
    ?assertEqual(2, Imported),
    {ok, Value} = dui_redis_client:q([<<"GET">>, <<"m6t:a">>]),
    ?assertEqual(<<"v">>, Value),
    _ = file:del_dir_r(Dir),
    %% cluster on standalone returns an error
    ?assertMatch({error, _}, dui_redis_client:cluster_nodes()),
    ok = dui_redis_client:disconnect().

live_protobuf_decode_test_() ->
    case redis_available() of
        true -> {timeout, 30, fun live_protobuf_decode/0};
        false -> []
    end.

live_protobuf_decode() ->
    ensure_client(),
    ok = dui_redis_client:connect(#{host => <<"localhost">>, port => 6379, db => 0}),
    {ok, _} = dui_redis_client:q([<<"FLUSHDB">>]),
    Msg = <<8, 150, 1, 18, 2, "hi">>,
    {ok, _} = dui_redis_client:set_string(<<"m7:pb">>, Msg, 0),
    {ok, V} = dui_redis_client:value_preview(<<"m7:pb">>),
    ?assertEqual(protobuf, maps:get(type, V)),
    ?assert(binary:match(maps:get(decoded, V), <<"1: 150">>) =/= nomatch),
    {ok, _} = dui_redis_client:set_string(<<"m7:json">>, <<"{\"a\":1}">>, 0),
    {ok, JV} = dui_redis_client:value_preview(<<"m7:json">>),
    ?assertEqual(true, maps:get(json, JV)),
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
