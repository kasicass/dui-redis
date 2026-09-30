-module(dui_redis_root_tests).

-include_lib("eunit/include/eunit.hrl").
-include("dui_redis.hrl").

skeleton_renders_test() ->
    {Pid, Dir} = start_root(),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"dui-redis">>)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Connections">>)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"No connections saved">>)),
    cleanup(Pid, Dir).

help_toggle_test() ->
    {Pid, Dir} = start_root(),
    ok = educkui_test:send_key(Pid, <<"?">>),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"toggle this help">>)),
    ok = educkui_test:send_key(Pid, esc),
    ok = educkui_test:sync(Pid),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"No connections saved">>)),
    cleanup(Pid, Dir).

initial_resize_delivered_test() ->
    {Pid, Dir} = start_root(),
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
    save_conn(Path, <<"Local">>, <<"localhost">>, 6379),
    Pid = start_root_path(Path),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 300)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Local">>)),
    cleanup(Pid, Dir).

add_connection_via_form_test() ->
    {Pid, Dir} = start_root(),
    ok = educkui_test:wait_until(Pid, fun(S) -> S#dui_state.loading =:= false end, 100),
    ok = educkui_test:send_key(Pid, <<"a">>),
    ok = educkui_test:sync(Pid),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Add Connection">>)),
    ok = educkui_test:send_key(Pid, <<"M">>),
    ok = educkui_test:send_key(Pid, <<"y">>),
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 300)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"My">>)),
    cleanup(Pid, Dir).

edit_connection_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    save_conn(Path, <<"My">>, <<"localhost">>, 6379),
    Pid = start_root_path(Path),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 300)),
    ok = educkui_test:send_key(Pid, <<"e">>),
    ok = educkui_test:sync(Pid),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Edit Connection">>)),
    ok = educkui_test:send_key(Pid, <<"X">>),
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> [maps:get(name, C) || C <- S#dui_state.connections] =:= [<<"MyX">>] end, 100)),
    cleanup(Pid, Dir).

delete_connection_via_confirm_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    save_conn(Path, <<"Doomed">>, <<"localhost">>, 6379),
    Pid = start_root_path(Path),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 300)),
    ok = educkui_test:send_key(Pid, <<"d">>),
    ok = educkui_test:sync(Pid),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Confirm Delete">>)),
    ok = educkui_test:send_key(Pid, <<"y">>),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.connections =:= [] end, 100)),
    cleanup(Pid, Dir).

live_connect_flow_test_() ->
    case redis_available() of
        true -> {timeout, 40, fun live_connect_flow/0};
        false -> []
    end.

live_connect_flow() ->
    reset_app(),
    seed_keys(),
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    save_conn(Path, <<"Local">>, <<"localhost">>, 6379),
    Pid = start_root_path(Path),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 300)),
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.connected end, 300)),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.keys) >= 1 end, 200)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"m2:str">>)),
    cleanup(Pid, Dir),
    _ = application:stop(dui_redis),
    ok.

live_keys_browse_test_() ->
    case redis_available() of
        true -> {timeout, 40, fun live_keys_browse/0};
        false -> []
    end.

live_keys_browse() ->
    reset_app(),
    seed_keys(),
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    save_conn(Path, <<"Local">>, <<"localhost">>, 6379),
    Pid = educkui_test:start(#{root => dui_redis_root, size => {24, 120},
                               init_args => [{opts, #{config_path => Path}}]}),
    ok = educkui_test:send_event(Pid, educkui_event:resize(120, 24)),
    ?assertEqual(ok, educkui_test:sync(Pid)),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 300)),
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.keys) >= 3 end, 200)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Filter:">>)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Preview">>)),
    %% navigate and sort should not crash
    ok = educkui_test:send_keys(Pid, [<<"j">>, <<"j">>, <<"s">>, <<"S">>, <<"g">>, <<"G">>]),
    ?assertEqual(ok, educkui_test:sync(Pid)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"m2:str">>)),
    %% typing 'q' in the filter must NOT quit the app
    ok = educkui_test:send_key(Pid, <<"/">>),
    ok = educkui_test:send_keys(Pid, [<<"q">>, <<"u">>, <<"e">>]),
    ?assertEqual(ok, educkui_test:sync(Pid)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"que">>)),
    ok = educkui_test:send_key(Pid, esc),
    ?assertEqual(ok, educkui_test:sync(Pid)),
    cleanup(Pid, Dir),
    _ = application:stop(dui_redis),
    ok.

live_key_detail_test_() ->
    case redis_available() of
        true -> {timeout, 40, fun live_key_detail/0};
        false -> []
    end.

live_key_detail() ->
    reset_app(),
    seed_keys(),
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    save_conn(Path, <<"Local">>, <<"localhost">>, 6379),
    Pid = educkui_test:start(#{root => dui_redis_root, size => {24, 120},
                               init_args => [{opts, #{config_path => Path}}]}),
    ok = educkui_test:send_event(Pid, educkui_event:resize(120, 24)),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 300)),
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.keys) >= 3 end, 200)),
    %% keys are sorted ascending: last is m2:str
    ok = educkui_test:send_key(Pid, <<"G">>),
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.current_value =/= undefined end, 100)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"hello">>)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"type: string">>)),
    %% edit the string value
    ok = educkui_test:send_key(Pid, <<"e">>),
    ?assertEqual(ok, educkui_test:sync(Pid)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Edit value">>)),
    ok = educkui_test:send_key(Pid, 'end'),
    ok = educkui_test:send_key(Pid, <<"!">>),
    ok = educkui_test:send_event(Pid, educkui_event:key(<<"s">>, [{modifiers, [ctrl]}])),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) ->
            case S#dui_state.current_value of
                #{text := <<"hello!">>} -> true;
                _ -> false
            end
        end, 100)),
    %% TTL prompt opens and submits
    ok = educkui_test:send_key(Pid, <<"t">>),
    ?assertEqual(ok, educkui_test:sync(Pid)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"TTL seconds">>)),
    ok = educkui_test:send_keys(Pid, [<<"1">>, <<"0">>, <<"0">>]),
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.screen =:= key_detail end, 100)),
    cleanup(Pid, Dir),
    _ = application:stop(dui_redis),
    ok.

live_favorites_and_tree_test_() ->
    case redis_available() of
        true -> {timeout, 40, fun live_favorites_and_tree/0};
        false -> []
    end.

live_favorites_and_tree() ->
    reset_app(),
    seed_keys(),
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    save_conn(Path, <<"Local">>, <<"localhost">>, 6379),
    Pid = educkui_test:start(#{root => dui_redis_root, size => {24, 120},
                               init_args => [{opts, #{config_path => Path}}]}),
    ok = educkui_test:send_event(Pid, educkui_event:resize(120, 24)),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 300)),
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.keys) >= 3 end, 200)),
    %% tree view
    ok = educkui_test:send_key(Pid, <<"W">>),
    ?assertEqual(ok, educkui_test:sync(Pid)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Tree">>)),
    ok = educkui_test:send_key(Pid, esc),
    %% favorite the first key from its detail
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.current_value =/= undefined end, 100)),
    ok = educkui_test:send_key(Pid, <<"F">>),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) ->
            case S#dui_state.status of
                {info, <<"Added to favorites">>} -> true;
                _ -> false
            end
        end, 100)),
    ok = educkui_test:send_key(Pid, esc),
    ok = educkui_test:send_key(Pid, <<"F">>),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) ->
            S#dui_state.results_purpose =:= favorites
            andalso length(S#dui_state.results) >= 1
        end, 150)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Favorites">>)),
    cleanup(Pid, Dir),
    _ = application:stop(dui_redis),
    ok.

live_monitoring_screens_test_() ->
    case redis_available() of
        true -> {timeout, 40, fun live_monitoring_screens/0};
        false -> []
    end.

live_monitoring_screens() ->
    reset_app(),
    seed_keys(),
    set_expiring_key(),
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    save_conn(Path, <<"Local">>, <<"localhost">>, 6379),
    Pid = educkui_test:start(#{root => dui_redis_root, size => {24, 100},
                               init_args => [{opts, #{config_path => Path}}]}),
    ok = educkui_test:send_event(Pid, educkui_event:resize(100, 24)),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 300)),
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.connected end, 300)),
    %% server info
    ok = educkui_test:send_key(Pid, <<"i">>),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.screen =:= server_info end, 150)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Server Info">>)),
    ok = educkui_test:send_key(Pid, esc),
    %% live metrics
    ok = educkui_test:send_key(Pid, <<"m">>),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.screen =:= live_metrics
                  andalso S#dui_state.metrics =/= [] end, 150)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Live Metrics">>)),
    ok = educkui_test:send_key(Pid, esc),
    %% expiring keys
    ok = educkui_test:send_event(Pid, educkui_event:key(<<"x">>, [{modifiers, [ctrl]}])),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.screen =:= expiring_keys end, 200)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Expiring Keys">>)),
    cleanup(Pid, Dir),
    _ = application:stop(dui_redis),
    ok.

start_root() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    {start_root_path(Path), Dir}.

start_root_path(Path) ->
    educkui_test:start(#{root => dui_redis_root, size => {24, 80},
                         init_args => [{opts, #{config_path => Path}}]}).

save_conn(Path, Name, Host, Port) ->
    {ok, _} = dui_redis_config:add_connection(Path,
        #{name => Name, host => Host, port => Port}),
    ok.

seed_keys() ->
    {ok, C} = eredis:start_link([{host, "localhost"}, {port, 6379}, {database, 0}]),
    _ = eredis:q(C, [<<"FLUSHDB">>]),
    _ = eredis:q(C, [<<"SET">>, <<"m2:str">>, <<"hello">>]),
    _ = eredis:q(C, [<<"RPUSH">>, <<"m2:list">>, <<"a">>, <<"b">>]),
    _ = eredis:q(C, [<<"HSET">>, <<"m2:hash">>, <<"f">>, <<"v">>]),
    eredis:stop(C),
    ok.

set_expiring_key() ->
    {ok, C} = eredis:start_link([{host, "localhost"}, {port, 6379}, {database, 0}]),
    _ = eredis:q(C, [<<"SET">>, <<"m5:expiring">>, <<"v">>, <<"EX">>, <<"60">>]),
    eredis:stop(C),
    ok.

cleanup(Pid, Dir) ->
    ok = educkui_test:stop(Pid),
    _ = file:del_dir_r(Dir),
    ok.

reset_app() ->
    _ = application:stop(dui_redis),
    stop_client(),
    {ok, _} = application:ensure_all_started(dui_redis),
    ok.

stop_client() ->
    case whereis(dui_redis_client) of
        undefined -> ok;
        Pid -> catch gen_server:stop(Pid), ok
    end.

redis_available() ->
    case gen_tcp:connect("127.0.0.1", 6379, [binary, {active, false}], 300) of
        {ok, Sock} -> gen_tcp:close(Sock), true;
        {error, _} -> false
    end.

mk_tmp() ->
    Dir = filename:join("/tmp", "dui_redis_root_test_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.
