-module(dui_redis_search_tests).

-include_lib("eunit/include/eunit.hrl").

regex_match_test() ->
    ?assert(dui_redis_search:regex_match(<<"^foo">>, <<"foobar">>)),
    ?assertNot(dui_redis_search:regex_match(<<"^foo">>, <<"barfoo">>)),
    ?assert(dui_redis_search:regex_match(<<"o+">>, <<"foo">>)).

compile_regex_invalid_test() ->
    ?assertMatch({error, _}, dui_redis_search:compile_regex(<<"(unclosed">>)),
    ?assertMatch({ok, _}, dui_redis_search:compile_regex(<<"^a.*z$">>)).

compile_regex_too_long_test() ->
    Long = binary:copy(<<"a">>, 2000),
    ?assertEqual({error, pattern_too_long}, dui_redis_search:compile_regex(Long)).

fuzzy_contains_scores_highest_test() ->
    ?assert(dui_redis_search:fuzzy_score(<<"foobar">>, <<"foo">>) >= 100).

fuzzy_subsequence_test() ->
    ?assert(dui_redis_search:fuzzy_score(<<"a_b_c">>, <<"abc">>) > 0),
    ?assertEqual(0, dui_redis_search:fuzzy_score(<<"xyz">>, <<"abc">>)).

fuzzy_rank_orders_and_bounds_test() ->
    Keys = [#{key => <<"foobar">>}, #{key => <<"f_o_o">>}, #{key => <<"nope">>}],
    Ranked = dui_redis_search:fuzzy_rank(Keys, <<"foo">>, 1),
    ?assertEqual([<<"foobar">>], [maps:get(key, K) || K <- Ranked]),
    ?assertEqual(1, length(Ranked)).

value_contains_test() ->
    Value = #{type => string, text => <<"hello world">>},
    ?assert(dui_redis_search:value_contains(<<"world">>, Value)),
    ?assertNot(dui_redis_search:value_contains(<<"zzz">>, Value)).

diff_identical_test() ->
    V = #{type => string, text => <<"a\nb">>},
    ?assertEqual(<<"(identical)">>, dui_redis_search:diff(V, V)).

diff_changed_test() ->
    V1 = #{type => string, text => <<"a\nb">>},
    V2 = #{type => string, text => <<"a\nc">>},
    Diff = dui_redis_search:diff(V1, V2),
    ?assert(binary:match(Diff, <<"- b">>) =/= nomatch),
    ?assert(binary:match(Diff, <<"+ c">>) =/= nomatch).
