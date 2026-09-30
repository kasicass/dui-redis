-module(dui_redis_tree_tests).

-include_lib("eunit/include/eunit.hrl").

build_roots_test() ->
    Nodes = dui_redis_tree:build([<<"a:b:c">>, <<"a:e">>, <<"x">>], <<":">>),
    ?assertEqual([<<"a">>, <<"x">>], [maps:get(name, N) || N <- Nodes]).

all_paths_test() ->
    Nodes = dui_redis_tree:build([<<"a:b:c">>, <<"a:b:d">>, <<"a:e">>], <<":">>),
    Paths = dui_redis_tree:all_paths(Nodes),
    ?assert(lists:member(<<"a">>, Paths)),
    ?assert(lists:member(<<"a:b">>, Paths)),
    ?assert(lists:member(<<"a:b:c">>, Paths)),
    ?assert(lists:member(<<"a:b:d">>, Paths)),
    ?assert(lists:member(<<"a:e">>, Paths)).

flatten_collapsed_test() ->
    Nodes = dui_redis_tree:build([<<"a:b">>, <<"x">>], <<":">>),
    Flat = dui_redis_tree:flatten(Nodes, []),
    ?assertEqual([<<"a">>, <<"x">>],
                 [maps:get(name, N) || {_D, N} <- Flat]).

flatten_expanded_test() ->
    Nodes = dui_redis_tree:build([<<"a:b:c">>, <<"a:e">>, <<"x">>], <<":">>),
    Flat = dui_redis_tree:flatten(Nodes, [<<"a">>]),
    ?assertEqual([{0, <<"a">>}, {1, <<"a:b">>}, {1, <<"a:e">>}, {0, <<"x">>}],
                 [{D, maps:get(path, N)} || {D, N} <- Flat]).

flatten_nested_expanded_test() ->
    Nodes = dui_redis_tree:build([<<"a:b:c">>, <<"a:e">>], <<":">>),
    Flat = dui_redis_tree:flatten(Nodes, [<<"a">>, <<"a:b">>]),
    DepthMap = [{D, maps:get(path, N)} || {D, N} <- Flat],
    ?assert(lists:member({2, <<"a:b:c">>}, DepthMap)).

is_key_flag_test() ->
    Nodes = dui_redis_tree:build([<<"a:b">>], <<":">>),
    [A] = Nodes,
    ?assertNot(maps:get(is_key, A)),
    [B] = maps:get(children, A),
    ?assert(maps:get(is_key, B)).
