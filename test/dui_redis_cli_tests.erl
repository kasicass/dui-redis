-module(dui_redis_cli_tests).

-include_lib("eunit/include/eunit.hrl").

parse_defaults_test() ->
    {ok, Opts} = dui_redis_cli:parse([]),
    ?assertEqual(false, maps:get(version, Opts)),
    ?assertEqual(false, maps:get(update, Opts)),
    ?assertEqual(undefined, maps:get(connection, Opts)),
    ?assertEqual(1000, maps:get(scan_size, Opts)),
    ?assertEqual(true, maps:get(include_types, Opts)).

parse_version_test() ->
    {ok, Opts} = dui_redis_cli:parse(["--version"]),
    ?assertEqual(true, maps:get(version, Opts)).

parse_quick_connect_test() ->
    {ok, Opts} = dui_redis_cli:parse(
        ["--host", "localhost", "-p", "6380", "-n", "2", "-a", "secret"]),
    Conn = maps:get(connection, Opts),
    ?assertEqual(<<"localhost">>, maps:get(host, Conn)),
    ?assertEqual(6380, maps:get(port, Conn)),
    ?assertEqual(2, maps:get(db, Conn)),
    ?assertEqual(<<"secret">>, maps:get(password, Conn)),
    ?assertEqual(<<"localhost:6380">>, maps:get(name, Conn)).

parse_name_override_test() ->
    {ok, Opts} = dui_redis_cli:parse(["-h", "10.0.0.1", "--name", "Prod"]),
    Conn = maps:get(connection, Opts),
    ?assertEqual(<<"Prod">>, maps:get(name, Conn)).

parse_cluster_tls_test() ->
    {ok, Opts} = dui_redis_cli:parse(
        ["-h", "redis", "--cluster", "--tls", "--tls-ca", "/ca.pem",
         "--tls-skip-verify"]),
    Conn = maps:get(connection, Opts),
    ?assertEqual(true, maps:get(use_cluster, Conn)),
    ?assertEqual(true, maps:get(use_tls, Conn)),
    Tls = maps:get(tls_config, Conn),
    ?assertEqual(<<"/ca.pem">>, maps:get(ca_file, Tls)),
    ?assertEqual(true, maps:get(insecure_skip_verify, Tls)).

parse_scan_options_test() ->
    {ok, Opts} = dui_redis_cli:parse(["--scan-size", "500", "--include-types", "false"]),
    ?assertEqual(500, maps:get(scan_size, Opts)),
    ?assertEqual(false, maps:get(include_types, Opts)).

parse_bad_port_test() ->
    ?assertMatch({error, _}, dui_redis_cli:parse(["-p", "notanumber"])).

format_error_test() ->
    {error, Reason} = dui_redis_cli:parse(["-p", "notanumber"]),
    Formatted = dui_redis_cli:format_error(Reason),
    ?assert(is_list(Formatted) orelse is_binary(Formatted)).
