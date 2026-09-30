-module(dui_redis_history_tests).

-include_lib("eunit/include/eunit.hrl").

add_and_entries_test() ->
    H0 = dui_redis_history:new(),
    H1 = dui_redis_history:add(H0, <<"k">>, #{type => string}, <<"set">>),
    H2 = dui_redis_history:add(H1, <<"k2">>, #{type => list}, <<"delete">>),
    ?assertEqual(2, length(dui_redis_history:entries(H2))),
    %% newest first
    [Newest | _] = dui_redis_history:entries(H2),
    ?assertEqual(<<"k2">>, maps:get(key, Newest)).

filter_by_key_test() ->
    H0 = dui_redis_history:new(),
    H1 = dui_redis_history:add(H0, <<"k">>, #{}, <<"set">>),
    H2 = dui_redis_history:add(H1, <<"other">>, #{}, <<"set">>),
    Entries = dui_redis_history:entries(H2, <<"k">>),
    ?assertEqual(1, length(Entries)),
    ?assertEqual(<<"k">>, maps:get(key, hd(Entries))).

trims_to_max_test() ->
    H0 = dui_redis_history:new(2),
    H1 = lists:foldl(
        fun(I, H) -> dui_redis_history:add(H, integer_to_binary(I), #{}, <<"set">>) end,
        H0, lists:seq(1, 5)),
    Entries = dui_redis_history:entries(H1),
    ?assertEqual(2, length(Entries)),
    ?assertEqual(<<"5">>, maps:get(key, hd(Entries))).

clear_test() ->
    H0 = dui_redis_history:new(),
    H1 = dui_redis_history:add(H0, <<"k">>, #{}, <<"set">>),
    ?assertEqual([], dui_redis_history:entries(dui_redis_history:clear(H1))).
