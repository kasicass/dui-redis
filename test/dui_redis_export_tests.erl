-module(dui_redis_export_tests).

-include_lib("eunit/include/eunit.hrl").

encode_list_test() ->
    V = #{type => list, items => [<<"a">>, <<"b">>]},
    M = dui_redis_export:encode(V, 60),
    ?assertEqual(<<"list">>, maps:get(<<"type">>, M)),
    ?assertEqual(60, maps:get(<<"ttl">>, M)),
    ?assertEqual([<<"a">>, <<"b">>], maps:get(<<"value">>, M)).

encode_hash_test() ->
    V = #{type => hash, items => [{<<"f">>, <<"v">>}]},
    M = dui_redis_export:encode(V, -1),
    ?assertEqual(#{<<"f">> => <<"v">>}, maps:get(<<"value">>, M)).

encode_zset_test() ->
    V = #{type => zset, items => [{<<"m">>, 1.5}]},
    M = dui_redis_export:encode(V, -1),
    ?assertEqual([#{<<"member">> => <<"m">>, <<"score">> => 1.5}],
                 maps:get(<<"value">>, M)).

encode_string_test() ->
    M = dui_redis_export:encode(#{type => string, text => <<"hi">>}, 0),
    ?assertEqual(<<"hi">>, maps:get(<<"value">>, M)).

decode_test() ->
    Meta = #{<<"type">> => <<"list">>, <<"ttl">> => 60, <<"value">> => [<<"a">>]},
    ?assertEqual({list, [<<"a">>], 60}, dui_redis_export:decode(Meta)).

decode_invalid_test() ->
    ?assertEqual(error, dui_redis_export:decode(not_a_map)).

json_roundtrip_test() ->
    V = #{type => zset, items => [{<<"m">>, 1.5}]},
    Meta = dui_redis_export:encode(V, 60),
    Bin = iolist_to_binary(json:encode(Meta)),
    Decoded = json:decode(Bin),
    ?assertEqual({zset, [#{<<"member">> => <<"m">>, <<"score">> => 1.5}], 60},
                 dui_redis_export:decode(Decoded)).
