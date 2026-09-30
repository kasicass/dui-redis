%% @doc Minimal JSON syntax highlighting into styled spans.
%%
%% Produces `[{Text, Style}]' spans suitable for `educkui_widget_text_view'.
%% The tokenizer is intentionally simple (strings, numbers, keywords,
%% punctuation) and never fails: unknown bytes are emitted as plain text.
-module(dui_redis_json).

-export([lines/1, spans/1]).

-type span() :: {binary(), map() | undefined}.

%% @doc Highlights multi-line JSON into lines of spans.
-spec lines(binary()) -> [[span()]].
lines(Text) ->
    [spans(Line) || Line <- binary:split(Text, <<"\n">>, [global])].

%% @doc Highlights a single line of JSON.
-spec spans(binary()) -> [span()].
spans(Line) ->
    merge(tokenize(Line, [])).

%% ---------------------------------------------------------------------------

-define(STYLE_KEY, #{fg => yellow}).
-define(STYLE_STRING, #{fg => green}).
-define(STYLE_NUMBER, #{fg => magenta}).
-define(STYLE_KEYWORD, #{fg => cyan}).
-define(STYLE_PUNCT, #{fg => bright_black}).
-define(STYLE_PLAIN, undefined).

-spec tokenize(binary(), [span()]) -> [span()].
tokenize(<<>>, Acc) ->
    lists:reverse(Acc);
tokenize(<<C, Rest/binary>>, Acc) when C =:= $\s; C =:= $\t; C =:= $\r ->
    tokenize(Rest, [{<<C>>, ?STYLE_PLAIN} | Acc]);
tokenize(<<"\"", _/binary>> = Bin, Acc) ->
    {Str, Rest} = read_string(Bin),
    Style = case key_follows(Rest) of
        true -> ?STYLE_KEY;
        false -> ?STYLE_STRING
    end,
    tokenize(Rest, [{Str, Style} | Acc]);
tokenize(<<C, _/binary>> = Bin, Acc) when C =:= $-; C >= $0, C =< $9 ->
    {Num, Rest} = read_while(Bin, fun is_number_char/1),
    tokenize(Rest, [{Num, ?STYLE_NUMBER} | Acc]);
tokenize(<<"true", Rest/binary>>, Acc) ->
    tokenize(Rest, [{<<"true">>, ?STYLE_KEYWORD} | Acc]);
tokenize(<<"false", Rest/binary>>, Acc) ->
    tokenize(Rest, [{<<"false">>, ?STYLE_KEYWORD} | Acc]);
tokenize(<<"null", Rest/binary>>, Acc) ->
    tokenize(Rest, [{<<"null">>, ?STYLE_KEYWORD} | Acc]);
tokenize(<<C, Rest/binary>>, Acc) ->
    tokenize(Rest, [{<<C>>, ?STYLE_PUNCT} | Acc]).

-spec read_string(binary()) -> {binary(), binary()}.
read_string(<<"\"", Rest/binary>>) ->
    read_string(Rest, <<"\"">>).

-spec read_string(binary(), binary()) -> {binary(), binary()}.
read_string(<<>>, Acc) ->
    {Acc, <<>>};
read_string(<<"\\", C, Rest/binary>>, Acc) ->
    read_string(Rest, <<Acc/binary, "\\", C>>);
read_string(<<"\"", Rest/binary>>, Acc) ->
    {<<Acc/binary, "\"">>, Rest};
read_string(<<C, Rest/binary>>, Acc) ->
    read_string(Rest, <<Acc/binary, C>>).

-spec key_follows(binary()) -> boolean().
key_follows(Bin) ->
    case skip_ws(Bin) of
        <<":", _/binary>> -> true;
        _ -> false
    end.

-spec skip_ws(binary()) -> binary().
skip_ws(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r ->
    skip_ws(Rest);
skip_ws(Bin) ->
    Bin.

-spec read_while(binary(), fun((integer()) -> boolean())) -> {binary(), binary()}.
read_while(Bin, Pred) ->
    read_while(Bin, Pred, <<>>).

-spec read_while(binary(), fun((integer()) -> boolean()), binary()) -> {binary(), binary()}.
read_while(<<C, Rest/binary>>, Pred, Acc) ->
    case Pred(C) of
        true -> read_while(Rest, Pred, <<Acc/binary, C>>);
        false -> {Acc, <<C, Rest/binary>>}
    end;
read_while(<<>>, _Pred, Acc) ->
    {Acc, <<>>}.

-spec is_number_char(integer()) -> boolean().
is_number_char(C) ->
    (C >= $0 andalso C =< $9) orelse C =:= $. orelse C =:= $-
        orelse C =:= $e orelse C =:= $E orelse C =:= $+.

%% @doc Merges adjacent spans that share a style.
-spec merge([span()]) -> [span()].
merge([]) -> [];
merge([{Text, Style} | Rest]) ->
    merge(Rest, Text, Style, []).

-spec merge([span()], binary(), map() | undefined, [span()]) -> [span()].
merge([{Text, Style} | Rest], AccText, Style, Acc) ->
    merge(Rest, <<AccText/binary, Text/binary>>, Style, Acc);
merge([{Text, Style2} | Rest], AccText, Style, Acc) ->
    merge(Rest, Text, Style2, [{AccText, Style} | Acc]);
merge([], AccText, Style, Acc) ->
    lists:reverse([{AccText, Style} | Acc]).
