-module(dui_redis_root_tests).

-include_lib("eunit/include/eunit.hrl").
-include("dui_redis.hrl").

skeleton_renders_test() ->
    {Pid, Dir} = start_root(),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"dui-redis">>)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Connections">>)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"no saved connections">>)),
    cleanup(Pid, Dir).

help_toggle_test() ->
    {Pid, Dir} = start_root(),
    ok = educkui_test:send_key(Pid, <<"?">>),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Global shortcuts">>)),
    ok = educkui_test:send_key(Pid, esc),
    ok = educkui_test:sync(Pid),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"no saved connections">>)),
    cleanup(Pid, Dir).

initial_resize_delivered_test() ->
    {Pid, Dir} = start_root(),
    %% educkui delivers the initial size to the root component (E2).
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.size =:= {24, 80} end, 50)),
    cleanup(Pid, Dir).

resize_delivered_test() ->
    {Pid, Dir} = start_root(),
    ok = educkui_test:send_event(Pid, educkui_event:resize(100, 30)),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.size =:= {30, 100} end, 50)),
    cleanup(Pid, Dir).

interval_tick_test() ->
    {Pid, Dir} = start_root(),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.ticks >= 1 end, 300)),
    cleanup(Pid, Dir).

config_loaded_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    ok = dui_redis_config:save(Path, #{
        connections => [#{id => 1, name => <<"Local">>, host => <<"localhost">>,
                          port => 6379}],
        favorites => [], recent_keys => [], templates => [],
        tree_separator => <<":">>, max_recent_keys => 20,
        max_value_history => 50, watch_interval_ms => 1000}),
    Pid = educkui_test:start(#{root => dui_redis_root, size => {24, 80},
                               init_args => [{opts, #{config_path => Path}}]}),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 100)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Local (localhost:6379)">>)),
    cleanup(Pid, Dir).

%% ---------------------------------------------------------------------------

start_root() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    Pid = educkui_test:start(#{root => dui_redis_root, size => {24, 80},
                               init_args => [{opts, #{config_path => Path}}]}),
    {Pid, Dir}.

cleanup(Pid, Dir) ->
    ok = educkui_test:stop(Pid),
    _ = file:del_dir_r(Dir),
    ok.

mk_tmp() ->
    Dir = filename:join("/tmp", "dui_redis_root_test_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.
