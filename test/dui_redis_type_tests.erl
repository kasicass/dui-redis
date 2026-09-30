-module(dui_redis_type_tests).

-include_lib("eunit/include/eunit.hrl").

to_type_test() ->
    ?assertEqual(string, dui_redis_type:to_type(<<"string">>)),
    ?assertEqual(list, dui_redis_type:to_type(<<"list">>)),
    ?assertEqual(zset, dui_redis_type:to_type(<<"zset">>)),
    ?assertEqual(json, dui_redis_type:to_type(<<"ReJSON-RL">>)),
    ?assertEqual(none, dui_redis_type:to_type(<<"none">>)),
    ?assertEqual(string, dui_redis_type:to_type(<<"unknown">>)).

is_utf8_test() ->
    ?assert(dui_redis_type:is_utf8(<<"hello">>)),
    ?assert(dui_redis_type:is_utf8(<<"你好"/utf8>>)),
    ?assertNot(dui_redis_type:is_utf8(<<255, 0, 1>>)),
    ?assert(dui_redis_type:is_utf8(<<>>)).

detect_string_subtype_test() ->
    ?assertEqual(hll, dui_redis_type:detect_string_subtype(<<"HYLLxxxx">>)),
    ?assertEqual(string, dui_redis_type:detect_string_subtype(<<"plain text">>)),
    ?assertEqual(bitmap, dui_redis_type:detect_string_subtype(<<1, 2, 255>>)),
    ?assertEqual(string, dui_redis_type:detect_string_subtype(<<>>)).

looks_like_geoscores_test() ->
    ?assertNot(dui_redis_type:looks_like_geoscores([])),
    ?assertNot(dui_redis_type:looks_like_geoscores([1.5, 100.0])),
    ?assert(dui_redis_type:looks_like_geoscores([1.5e15])),
    ?assert(dui_redis_type:looks_like_geoscores([1.5e15, 2.0e15])),
    ?assertNot(dui_redis_type:looks_like_geoscores([1.5e15, 1.5])).

sort_by_key_test() ->
    Keys = sample(),
    Sorted = dui_redis_type:sort_keys(Keys, key, true),
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], [maps:get(key, K) || K <- Sorted]),
    Desc = dui_redis_type:sort_keys(Keys, key, false),
    ?assertEqual([<<"c">>, <<"b">>, <<"a">>], [maps:get(key, K) || K <- Desc]).

sort_by_type_test() ->
    Sorted = dui_redis_type:sort_keys(sample(), type, true),
    Types = [maps:get(type, K) || K <- Sorted],
    ?assertEqual([list, string, string], Types).

sort_by_ttl_test() ->
    Sorted = dui_redis_type:sort_keys(sample(), ttl, true),
    %% keys with a TTL come first (5s, 10s), no-expiry last
    ?assertEqual([<<"c">>, <<"b">>, <<"a">>], [maps:get(key, K) || K <- Sorted]).

sample() ->
    [#{key => <<"b">>, type => string, ttl => 10},
     #{key => <<"a">>, type => list, ttl => -1},
     #{key => <<"c">>, type => string, ttl => 5}].
