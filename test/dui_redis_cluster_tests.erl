-module(dui_redis_cluster_tests).

-include_lib("eunit/include/eunit.hrl").

parse_nodes_test() ->
    Bin = <<"abc123 127.0.0.1:7000@17000 myself,master - 0 0 1 connected 0-5460\n"
            "def456 127.0.0.1:7001@17001 slave abc123 0 0 1 connected\n">>,
    Nodes = dui_redis_cluster:parse_nodes(Bin),
    ?assertEqual(2, length(Nodes)),
    [Master, Replica] = Nodes,
    ?assertEqual(<<"abc123">>, maps:get(id, Master)),
    ?assertEqual(<<"master">>, maps:get(role, Master)),
    ?assertEqual([<<"0-5460">>], maps:get(slots, Master)),
    ?assertEqual(<<"replica">>, maps:get(role, Replica)),
    ?assertEqual(<<"abc123">>, maps:get(master, Replica)).

parse_info_test() ->
    Bin = <<"cluster_enabled:1\ncluster_state:ok\ncluster_known_nodes:3\n">>,
    Info = dui_redis_cluster:parse_info(Bin),
    ?assertEqual(<<"1">>, maps:get(<<"cluster_enabled">>, Info)),
    ?assertEqual(<<"3">>, maps:get(<<"cluster_known_nodes">>, Info)).

empty_test() ->
    ?assertEqual([], dui_redis_cluster:parse_nodes(<<>>)),
    ?assertEqual(#{}, dui_redis_cluster:parse_info(<<>>)).
