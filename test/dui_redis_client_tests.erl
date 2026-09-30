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
