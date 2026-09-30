-module(dui_redis_decode_tests).

-include_lib("eunit/include/eunit.hrl").

%% field 1 (varint) = 150, field 2 (bytes) = "hi"
-define(MSG, <<8, 150, 1, 18, 2, "hi">>).

format_message_test() ->
    {ok, Text} = dui_redis_decode:format_protobuf(?MSG),
    ?assert(binary:match(Text, <<"1: 150">>) =/= nomatch),
    ?assert(binary:match(Text, <<"2:">>) =/= nomatch),
    ?assert(binary:match(Text, <<"hi">>) =/= nomatch).

invalid_protobuf_test() ->
    %% "hello" is not a valid message (bad wire type)
    ?assertEqual(error, dui_redis_decode:format_protobuf(<<"hello">>)),
    ?assertNot(dui_redis_decode:looks_like_protobuf(<<"hello">>)).

try_binary_raw_test() ->
    ?assertMatch({ok, #{format := <<"protobuf">>}}, dui_redis_decode:try_binary(?MSG)),
    ?assertEqual(not_binary, dui_redis_decode:try_binary(<<"hello world">>)),
    ?assertEqual(not_binary, dui_redis_decode:try_binary(<<>>)).

snappy_literal_test() ->
    %% varint length 5, literal tag (5-1)<<2 = 16, bytes "hello"
    ?assertEqual({ok, <<"hello">>}, dui_redis_decode:snappy_decode(<<5, 16, "hello">>)).

snappy_copy_test() ->
    %% length 4, literal "ab" (tag (2-1)<<2=4), copy2 offset 2 len 2
    ?assertEqual({ok, <<"abab">>}, dui_redis_decode:snappy_decode(<<4, 4, "ab", 6, 2, 0>>)).

snappy_bad_test() ->
    ?assertEqual(error, dui_redis_decode:snappy_decode(<<100, 16, "hi">>)).
