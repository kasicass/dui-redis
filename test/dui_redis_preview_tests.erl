-module(dui_redis_preview_tests).

-include_lib("eunit/include/eunit.hrl").

string_lines_test() ->
    Lines = dui_redis_preview:lines(#{type => string, text => <<"a\nb">>}, 10),
    ?assertEqual([<<"a">>, <<"b">>], Lines).

string_sanitizes_control_chars_test() ->
    Lines = dui_redis_preview:lines(#{type => string, text => <<"a", 7, "b">>}, 10),
    ?assertEqual([<<"a b">>], Lines).

list_lines_test() ->
    Lines = dui_redis_preview:lines(#{type => list, items => [<<"x">>, <<"y">>]}, 10),
    ?assertEqual([<<"1) x">>, <<"2) y">>], Lines).

list_truncates_to_max_test() ->
    Lines = dui_redis_preview:lines(#{type => list, items => [<<"x">>, <<"y">>, <<"z">>]}, 2),
    ?assertEqual([<<"1) x">>, <<"2) y">>], Lines).

zset_lines_test() ->
    Lines = dui_redis_preview:lines(#{type => zset, items => [{<<"m">>, 1.5}]}, 10),
    ?assertEqual([<<"1) m  1.5">>], Lines).

geo_lines_test() ->
    Lines = dui_redis_preview:lines(#{type => geo, items => [{<<"m">>, 1.0, 2.0}]}, 10),
    ?assertMatch([<<"1) m  (1.0000, 2.0000)">>], Lines).

hash_lines_test() ->
    Lines = dui_redis_preview:lines(#{type => hash, items => [{<<"f">>, <<"v">>}]}, 10),
    ?assertEqual([<<"1) f = v">>], Lines).

hll_lines_test() ->
    ?assertEqual([<<"HyperLogLog cardinality: 42">>],
                 dui_redis_preview:lines(#{type => hll, count => 42}, 10)).

none_lines_test() ->
    ?assertEqual([<<"(key does not exist)">>],
                 dui_redis_preview:lines(#{type => none}, 10)).

summary_test() ->
    ?assertEqual(<<"list">>, dui_redis_preview:summary(#{type => list})),
    ?assertEqual(<<"string  (preview - 1000 total)">>,
                 dui_redis_preview:summary(#{type => string, truncated => true, total => 1000})).

type_label_test() ->
    ?assertEqual(<<"hyperloglog">>, dui_redis_preview:type_label(hll)),
    ?assertEqual(<<"zset">>, dui_redis_preview:type_label(zset)).
