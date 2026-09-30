-module(dui_redis_json_tests).

-include_lib("eunit/include/eunit.hrl").

text_roundtrip(Spans) ->
    iolist_to_binary([Text || {Text, _Style} <- Spans]).

lines_single_test() ->
    Line = <<"{\"a\": 1}">>,
    [Spans] = dui_redis_json:lines(Line),
    ?assertEqual(Line, text_roundtrip(Spans)).

lines_multi_test() ->
    Text = <<"{\n  \"a\": true\n}">>,
    Lines = dui_redis_json:lines(Text),
    ?assertEqual(3, length(Lines)),
    ?assertEqual(Text, iolist_to_binary(
        lists:join(<<"\n">>, [text_roundtrip(L) || L <- Lines]))).

key_and_string_styles_test() ->
    [Spans] = dui_redis_json:lines(<<"{\"key\": \"value\"}">>),
    KeySpan = [S || {T, _} = S <- Spans, T =:= <<"\"key\"">>],
    ValSpan = [S || {T, _} = S <- Spans, T =:= <<"\"value\"">>],
    ?assertMatch([{_, #{fg := yellow}}], KeySpan),
    ?assertMatch([{_, #{fg := green}}], ValSpan).

number_and_keyword_styles_test() ->
    [Spans] = dui_redis_json:lines(<<"[1, true, null]">>),
    ?assertMatch([{_, #{fg := magenta}} | _],
                 [S || {T, _} = S <- Spans, T =:= <<"1">>]),
    ?assertMatch([{_, #{fg := cyan}} | _],
                 [S || {T, _} = S <- Spans, T =:= <<"true">>]),
    ?assertMatch([{_, #{fg := cyan}} | _],
                 [S || {T, _} = S <- Spans, T =:= <<"null">>]).

non_json_default_test() ->
    Line = <<"not json at all">>,
    [Spans] = dui_redis_json:lines(Line),
    ?assertEqual(Line, text_roundtrip(Spans)).
