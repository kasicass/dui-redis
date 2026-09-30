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
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"toggle help">>)),
    ok = educkui_test:send_key(Pid, esc),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.show_help =:= false end, 50)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"No connections saved">>)),
    cleanup(Pid, Dir).

mouse_click_selects_connection_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    save_conn(Path, <<"A">>, <<"localhost">>, 6379),
    save_conn(Path, <<"B">>, <<"localhost">>, 6379),
    save_conn(Path, <<"C">>, <<"localhost">>, 6379),
    Pid = educkui_test:start(#{root => dui_redis_root, size => {24, 80},
                               init_args => [{opts, #{config_path => Path}}]}),
    ok = educkui_test:send_event(Pid, educkui_event:resize(80, 24)),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 3 end, 500)),
    ok = educkui_test:render(Pid),
    %% Connection list rows start at screen row 10; the third row is Y=12.
    ok = educkui_test:send_event(Pid, educkui_event:mouse(press, left, 5, 12)),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.selected =:= 2 end, 100)),
    %% Keyboard still reaches the root after the mouse layer takes focus.
    ok = educkui_test:send_key(Pid, <<"k">>),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.selected =:= 1 end, 100)),
    cleanup(Pid, Dir).

monitor_list_scrolls_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    write_groups(Path, 30),
    Pid = educkui_test:start(#{root => dui_redis_root, size => {24, 80},
                               init_args => [{opts, #{config_path => Path}}]}),
    ok = educkui_test:send_event(Pid, educkui_event:resize(80, 24)),
    ok = educkui_test:send_key(Pid, <<"g">>),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.screen =:= groups
                  andalso length(S#dui_state.groups) =:= 30 end, 300)),
    ok = educkui_test:send_keys(Pid, lists:duplicate(25, <<"j">>)),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.row_selected =:= 25 end, 100)),
    %% The list must scroll so later rows are actually rendered.
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"g25">>)),
    cleanup(Pid, Dir).

%% @doc Renders every screen with representative data (no Redis needed) so a
%% crashing view function is caught.
render_all_screens_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    Pid = educkui_test:start(#{root => dui_redis_root, size => {30, 100},
                               init_args => [{opts, #{config_path => Path}}]}),
    ok = educkui_test:send_event(Pid, educkui_event:resize(100, 30)),
    lists:foreach(
        fun({Name, Actions}) ->
            lists:foreach(fun(A) -> ok = run_action(Pid, A) end, Actions),
            Expected = expected_screen(Name),
            ?assertEqual(ok, educkui_test:wait_until(Pid,
                fun(S) -> S#dui_state.screen =:= Expected end, 100)),
            _ = educkui_test:screen_text(Pid),
            ?assert(is_process_alive(Pid))
        end,
        render_steps()),
    cleanup(Pid, Dir).

run_action(Pid, {msg, Msg}) -> educkui_test:send_msg(Pid, Msg);
run_action(Pid, {key, Key}) -> educkui_test:send_key(Pid, Key).

expected_screen(connections) -> connections;
expected_screen(connection_form) -> connection_form;
expected_screen(test_connection) -> test_connection;
expected_screen(confirm_delete) -> confirm_delete;
expected_screen(keys) -> keys;
expected_screen(detail_string) -> key_detail;
expected_screen(detail_json) -> key_detail;
expected_screen(detail_list) -> key_detail;
expected_screen(detail_hash) -> key_detail;
expected_screen(editor) -> edit_value;
expected_screen(prompt) -> prompt;
expected_screen(results) -> results;
expected_screen(tree) -> tree;
expected_screen(result_text) -> result_text;
expected_screen(switch_db) -> switch_db;
expected_screen(server_info) -> server_info;
expected_screen(slow_log) -> slow_log;
expected_screen(client_list) -> client_list;
expected_screen(memory_stats) -> memory_stats;
expected_screen(live_metrics) -> live_metrics;
expected_screen(expiring) -> expiring_keys;
expected_screen(channels) -> pubsub_channels;
expected_screen(redis_config) -> redis_config;
expected_screen(cluster) -> cluster_info;
expected_screen(groups) -> groups;
expected_screen(logs) -> logs;
expected_screen(help) -> logs.

render_steps() ->
    Conn = #{id => 1, name => <<"Local">>, host => <<"localhost">>, port => 6379,
             db => 0, username => <<>>, password => <<>>,
             use_cluster => false, use_tls => false},
    Connected = {connected, ok},
    Keys = {keys_loaded, 0, {ok, #{keys => [#{key => <<"user:1">>, type => string, ttl => -1},
                                           #{key => <<"sess:a">>, type => hash, ttl => 60}],
                                    cursor => 0, total => 2}}},
    Str = {detail_loaded, <<"user:1">>, {ok, #{type => string, text => <<"hello">>}}},
    Json = {detail_loaded, <<"user:1">>,
            {ok, #{type => json, text => <<"{\"a\":1,\"b\":[2,3]}">>}}},
    List = {detail_loaded, <<"user:1">>, {ok, #{type => list, items => [<<"a">>, <<"b">>]}}},
    Hash = {detail_loaded, <<"user:1">>,
            {ok, #{type => hash, items => [{<<"f">>, <<"v">>}]}}},
    [
        {connections, [{msg, {connections_loaded, {ok, [Conn]}}}]},
        {connection_form, [{msg, {disconnected, ok}}, {key, <<"a">>}]},
        {test_connection, [{msg, {connection_tested, {ok, 5}}}]},
        {confirm_delete, [{msg, {disconnected, ok}},
                         {msg, {connections_loaded, {ok, [Conn]}}}, {key, <<"d">>}]},
        {keys, [{msg, Connected}, {msg, Keys}]},
        {detail_string, [{msg, Str}]},
        {detail_json, [{msg, Json}]},
        {detail_list, [{msg, List}]},
        {detail_hash, [{msg, Hash}]},
        {editor, [{msg, Str}, {key, <<"e">>}]},
        {prompt, [{msg, Str}, {key, <<"t">>}]},
        {results, [{msg, {favorites_loaded,
            {ok, [#{key => <<"user:1">>, label => <<"L">>, type => string}]}}}]},
        {tree, [{msg, Connected}, {msg, Keys}, {key, <<"W">>}]},
        {result_text, [{msg, {lua_result, {ok, <<"return 1">>}}}]},
        {switch_db, [{msg, Connected}, {key, <<"D">>}]},
        {server_info, [{msg, {server_info_loaded,
            {ok, #{version => <<"7">>, mode => <<"standalone">>}}}}]},
        {slow_log, [{msg, {slow_log_loaded,
            {ok, [#{id => 1, duration => 5, command => <<"GET">>}]}}}]},
        {client_list, [{msg, {clients_loaded,
            {ok, [#{id => 1, addr => <<"1:1">>, age => 1, db => 0, cmd => <<"get">>}]}}}]},
        {memory_stats, [{msg, {memory_stats_loaded, {ok, #{
            used => <<"1K">>, peak => <<"2K">>, rss => <<"1K">>,
            frag_ratio => <<"1.10">>, frag_bytes => <<"0">>, lua => <<"0">>,
            top_keys => [#{key => <<"k">>, type => string, size => 10}]}}}}]},
        {live_metrics, [{msg, Connected}, {key, <<"m">>},
            {msg, {live_metrics_loaded, {ok, #{ops => 1, clients => 1, blocked => 0,
                hits => 1, misses => 0, used_memory => 1024}}}}]},
        {expiring, [{msg, {expiring_loaded, {ok, [#{key => <<"k">>, ttl => 30}]}}}]},
        {channels, [{msg, {channels_loaded, {ok, [<<"news">>]}}}]},
        {redis_config, [{msg, {redis_config_loaded, {ok, #{<<"maxmemory">> => <<"0">>}}}}]},
        {cluster, [{msg, {cluster_loaded, {ok, [#{role => <<"master">>, addr => <<"1">>,
            slots => [<<"0-1">>]}]}}}]},
        {groups, [{msg, {groups_loaded, {ok, [#{name => <<"prod">>, connections => [1]}]}}}]},
        {logs, [{msg, Connected}, {key, <<"O">>}]},
        {help, [{key, <<"?">>}]}
    ].

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
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 500)),
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
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 500)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"My">>)),
    cleanup(Pid, Dir).

edit_connection_test() ->
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    save_conn(Path, <<"My">>, <<"localhost">>, 6379),
    Pid = start_root_path(Path),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 500)),
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
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 500)),
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
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 500)),
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
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 500)),
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
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 500)),
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
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 500)),
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
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 500)),
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

live_ops_screens_test_() ->
    case redis_available() of
        true -> {timeout, 40, fun live_ops_screens/0};
        false -> []
    end.

live_ops_screens() ->
    reset_app(),
    seed_keys(),
    Dir = mk_tmp(),
    Path = filename:join(Dir, "config.json"),
    save_conn(Path, <<"Local">>, <<"localhost">>, 6379),
    Pid = educkui_test:start(#{root => dui_redis_root, size => {24, 100},
                               init_args => [{opts, #{config_path => Path}}]}),
    ok = educkui_test:send_event(Pid, educkui_event:resize(100, 24)),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> length(S#dui_state.connections) =:= 1 end, 500)),
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.connected end, 300)),
    %% redis config
    ok = educkui_test:send_event(Pid, educkui_event:key(<<"g">>, [{modifiers, [ctrl]}])),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.screen =:= redis_config end, 150)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Redis Config">>)),
    ok = educkui_test:send_key(Pid, esc),
    %% pub/sub channels
    ok = educkui_test:send_key(Pid, <<"p">>),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) -> S#dui_state.screen =:= pubsub_channels end, 150)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Pub/Sub Channels">>)),
    ok = educkui_test:send_key(Pid, esc),
    %% bulk delete
    ok = educkui_test:send_key(Pid, <<"B">>),
    ?assertEqual(ok, educkui_test:sync(Pid)),
    ?assertEqual(ok, educkui_test:assert_text(Pid, <<"Pattern to delete">>)),
    ok = educkui_test:send_keys(Pid, [<<"m">>, <<"2">>, <<":">>, <<"*">>]),
    ok = educkui_test:send_key(Pid, enter),
    ?assertEqual(ok, educkui_test:wait_until(Pid,
        fun(S) ->
            case S#dui_state.status of
                {info, _} -> true;
                _ -> false
            end
        end, 200)),
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

write_groups(Path, N) ->
    Groups = [#{name => iolist_to_binary(io_lib:format("g~2..0b", [I])),
                color => <<>>, connections => []} || I <- lists:seq(1, N)],
    ok = dui_redis_config:save(Path, (dui_redis_config:defaults())#{groups => Groups}),
    ok.

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
    timer:sleep(100),
    stop_client(),
    _ = application:ensure_all_started(dui_redis),
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
    Dir = filename:join("/tmp", "dui_redis_root_test_" ++ os:getpid() ++ "_"
                        ++ integer_to_list(erlang:unique_integer([positive]))),
    _ = file:del_dir_r(Dir),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.
