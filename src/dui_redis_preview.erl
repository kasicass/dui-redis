%% @doc Renders a bounded Redis value into display lines.
%%
%% Pure: takes the value map produced by `dui_redis_client:value_preview/1'
%% and returns plain text lines for the preview panel.
-module(dui_redis_preview).

-export([lines/2, summary/1, type_label/1]).

%% @doc Returns at most `MaxLines' display lines for `Value'.
-spec lines(map(), pos_integer()) -> [binary()].
lines(#{type := none}, _MaxLines) ->
    [<<"(key does not exist)">>];
lines(#{type := string} = V, MaxLines) ->
    text_lines(maps:get(text, V, <<>>), MaxLines);
lines(#{type := hll} = V, _MaxLines) ->
    [<<"HyperLogLog cardinality: ", (int_bin(maps:get(count, V, 0)))/binary>>];
lines(#{type := bitmap} = V, MaxLines) ->
    BitCount = int_bin(maps:get(bitcount, V, 0)),
    Text = maps:get(text, V, <<>>),
    Preview = binary_snippet(Text, 64),
    take(MaxLines, [<<"Bit count: ", BitCount/binary>>,
                    <<"Bytes: ", (int_bin(byte_size(Text)))/binary>>,
                    <<"Raw: ", Preview/binary>>]);
lines(#{type := list} = V, MaxLines) ->
    numbered(maps:get(items, V, []), MaxLines);
lines(#{type := set} = V, MaxLines) ->
    numbered(maps:get(items, V, []), MaxLines);
lines(#{type := zset} = V, MaxLines) ->
    Members = [<<M/binary, "  ", (score_bin(S))/binary>>
               || {M, S} <- maps:get(items, V, [])],
    numbered(Members, MaxLines);
lines(#{type := geo} = V, MaxLines) ->
    Members = [<<M/binary, "  (", (float_bin(Lon))/binary, ", ",
                (float_bin(Lat))/binary, ")">>
               || {M, Lon, Lat} <- maps:get(items, V, [])],
    numbered(Members, MaxLines);
lines(#{type := hash} = V, MaxLines) ->
    Items = [<<F/binary, " = ", Val/binary>>
             || {F, Val} <- maps:get(items, V, [])],
    numbered(Items, MaxLines);
lines(#{type := stream} = V, MaxLines) ->
    Items = [<<Id/binary, "  ", (fields_bin(Fields))/binary>>
             || {Id, Fields} <- maps:get(items, V, [])],
    numbered(Items, MaxLines);
lines(#{type := json} = V, MaxLines) ->
    text_lines(maps:get(text, V, <<>>), MaxLines);
lines(#{type := protobuf} = V, MaxLines) ->
    Header = case maps:get(decoded_format, V, <<"protobuf">>) of
        F -> <<"[decoded ", F/binary, "]">>
    end,
    take(MaxLines, [Header | text_lines(maps:get(decoded, V, <<>>), MaxLines)]);
lines(#{type := Type} = V, MaxLines) ->
    case maps:get(items, V, undefined) of
        L when is_list(L) -> numbered([to_bin(I) || I <- L], MaxLines);
        _ -> [<<"(", (atom_to_binary(Type, utf8))/binary, ")">>]
    end.

%% @doc Short summary of a value (type + truncated marker).
-spec summary(map()) -> binary().
summary(#{type := Type} = V) ->
    Label = type_label(Type),
    case maps:get(truncated, V, false) of
        true ->
            Total = maps:get(total, V, 0),
            <<Label/binary, "  (preview - ", (int_bin(Total))/binary, " total)">>;
        false ->
            Label
    end.

%% @doc Human-readable type label.
-spec type_label(atom()) -> binary().
type_label(string) -> <<"string">>;
type_label(list) -> <<"list">>;
type_label(set) -> <<"set">>;
type_label(zset) -> <<"zset">>;
type_label(geo) -> <<"geo">>;
type_label(hash) -> <<"hash">>;
type_label(stream) -> <<"stream">>;
type_label(json) -> <<"json">>;
type_label(hll) -> <<"hyperloglog">>;
type_label(bitmap) -> <<"bitmap">>;
type_label(protobuf) -> <<"protobuf">>;
type_label(Other) -> atom_to_binary(Other, utf8).

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

-spec numbered([binary()], pos_integer()) -> [binary()].
numbered(Items, MaxLines) ->
    Lines = lists:mapfoldl(
        fun(Item, N) ->
            {<<(int_bin(N))/binary, ") ", Item/binary>>, N + 1}
        end, 1, lists:sublist(Items, MaxLines)),
    element(1, Lines).

-spec text_lines(binary(), pos_integer()) -> [binary()].
text_lines(Text, MaxLines) ->
    Lines = binary:split(Text, <<"\n">>, [global]),
    take(MaxLines, [sanitize(L) || L <- Lines]).

-spec take(pos_integer(), [T]) -> [T].
take(N, List) -> lists:sublist(List, N).

-spec fields_bin([{term(), term()}]) -> binary().
fields_bin(Fields) ->
    iolist_to_binary(
        lists:join(<<", ">>,
            [<<(to_bin(K))/binary, "=", (to_bin(V))/binary>> || {K, V} <- Fields])).

-spec binary_snippet(binary(), pos_integer()) -> binary().
binary_snippet(Bin, Max) ->
    case byte_size(Bin) =< Max of
        true -> sanitize(Bin);
        false -> <<(sanitize(binary:part(Bin, 0, Max)))/binary, "...">>
    end.

%% Replace control characters (except tab) so the terminal is not corrupted.
-spec sanitize(binary()) -> binary().
sanitize(Bin) ->
    << <<(sanitize_byte(B))>> || <<B>> <= Bin >>.

-spec sanitize_byte(byte()) -> byte().
sanitize_byte(B) when B >= 32, B =/= 127 -> B;
sanitize_byte(9) -> 9;
sanitize_byte(_) -> 32.

-spec int_bin(integer()) -> binary().
int_bin(I) -> integer_to_binary(I).

-spec score_bin(number()) -> binary().
score_bin(S) when is_integer(S) -> integer_to_binary(S);
score_bin(S) -> iolist_to_binary(io_lib:format("~p", [S])).

-spec float_bin(number()) -> binary().
float_bin(F) when is_float(F) -> iolist_to_binary(io_lib:format("~.4f", [F]));
float_bin(I) -> integer_to_binary(I).

-spec to_bin(term()) -> binary().
to_bin(B) when is_binary(B) -> sanitize(B);
to_bin(L) when is_list(L) -> sanitize(unicode:characters_to_binary(L));
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> sanitize(iolist_to_binary(io_lib:format("~p", [Other]))).
