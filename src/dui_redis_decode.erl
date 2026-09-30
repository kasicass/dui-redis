%% @doc Schema-less protobuf decoding (and a best-effort Snappy/S2 block decoder).
%%
%% Ported from redis-tui's `internal/decode'. Binary string values that look
%% like raw protobuf — or Snappy/S2-compressed protobuf — are pretty-printed
%% in `protoc --decode_raw' style without any schema.
%%
%% The Snappy decoder implements the block format; S2 streams that use only
%% Snappy-compatible opcodes decode correctly, otherwise detection simply
%% falls back to no decode.
-module(dui_redis_decode).

-export([try_binary/1, looks_like_protobuf/1, format_protobuf/1, snappy_decode/1]).

-define(MAX_TEXT, 65536).
-define(MAX_DEPTH, 8).
-define(MAX_FIELDS, 5000).
-define(MAX_FIELD_NUMBER, 536870911).

%% @doc Attempts s2 decompression then schema-less protobuf decoding.
-spec try_binary(binary()) -> {ok, map()} | not_binary.
try_binary(<<>>) ->
    not_binary;
try_binary(Raw) ->
    case snappy_decode(Raw) of
        {ok, Decompressed} when byte_size(Decompressed) > 0 ->
            case format_protobuf(Decompressed) of
                {ok, Text} ->
                    {ok, #{format => <<"s2+protobuf">>, text => Text,
                           raw_size => byte_size(Raw),
                           decoded_size => byte_size(Decompressed)}};
                error ->
                    try_raw(Raw)
            end;
        _ ->
            try_raw(Raw)
    end.

-spec try_raw(binary()) -> {ok, map()} | not_binary.
try_raw(Raw) ->
    case format_protobuf(Raw) of
        {ok, Text} ->
            {ok, #{format => <<"protobuf">>, text => Text,
                   raw_size => byte_size(Raw), decoded_size => byte_size(Raw)}};
        error ->
            not_binary
    end.

%% @doc True if `Raw' is Snappy/S2-wrapped or raw protobuf.
-spec looks_like_protobuf(binary()) -> boolean().
looks_like_protobuf(<<>>) -> false;
looks_like_protobuf(Raw) ->
    case snappy_decode(Raw) of
        {ok, Decompressed} when byte_size(Decompressed) > 0 ->
            is_valid_protobuf(Decompressed) orelse is_valid_protobuf(Raw);
        _ ->
            is_valid_protobuf(Raw)
    end.

%% @doc Pretty-prints a protobuf wire message.
-spec format_protobuf(binary()) -> {ok, binary()} | error.
format_protobuf(Bin) ->
    case is_valid_protobuf(Bin) of
        true ->
            Lines = format_message(Bin, 0),
            {ok, iolist_to_binary(Lines)};
        false ->
            error
    end.

%% ---------------------------------------------------------------------------
%% Wire parsing
%% ---------------------------------------------------------------------------

-spec is_valid_protobuf(binary()) -> boolean().
is_valid_protobuf(<<>>) -> false;
is_valid_protobuf(Bin) ->
    case consume_fields(Bin, 0) of
        {ok, _, Fields} when Fields > 0 -> true;
        _ -> false
    end.

-spec consume_fields(binary(), non_neg_integer()) ->
    {ok, binary(), non_neg_integer()} | error.
consume_fields(<<>>, Fields) ->
    {ok, <<>>, Fields};
consume_fields(Bin, Fields) ->
    case consume_varint(Bin) of
        {Tag, Rest} ->
            case valid_tag(Tag) of
                true ->
                    case consume_field(Tag band 7, Rest) of
                        {ok, Rest2} -> consume_fields(Rest2, Fields + 1);
                        error -> error
                    end;
                false ->
                    error
            end;
        error ->
            error
    end.

-spec valid_tag(non_neg_integer()) -> boolean().
valid_tag(Tag) ->
    Num = Tag bsr 3,
    Num >= 1 andalso Num =< ?MAX_FIELD_NUMBER.

-spec consume_field(non_neg_integer(), binary()) -> {ok, binary()} | error.
consume_field(0, Bin) ->
    case consume_varint(Bin) of
        {_, Rest} -> {ok, Rest};
        error -> error
    end;
consume_field(1, <<_:64, Rest/binary>>) ->
    {ok, Rest};
consume_field(1, _) ->
    error;
consume_field(2, Bin) ->
    case consume_bytes(Bin) of
        {_, Rest} -> {ok, Rest};
        error -> error
    end;
consume_field(5, <<_:32, Rest/binary>>) ->
    {ok, Rest};
consume_field(5, _) ->
    error;
consume_field(_, _) ->
    error.

-spec consume_varint(binary()) -> {non_neg_integer(), binary()} | error.
consume_varint(Bin) -> consume_varint(Bin, 0, 0).

-spec consume_varint(binary(), non_neg_integer(), non_neg_integer()) ->
    {non_neg_integer(), binary()} | error.
consume_varint(<<B, Rest/binary>>, Shift, Acc) when Shift < 64 ->
    Acc1 = Acc bor ((B band 127) bsl Shift),
    case B band 128 of
        0 -> {Acc1, Rest};
        _ -> consume_varint(Rest, Shift + 7, Acc1)
    end;
consume_varint(_, _, _) ->
    error.

-spec consume_bytes(binary()) -> {binary(), binary()} | error.
consume_bytes(Bin) ->
    case consume_varint(Bin) of
        {Len, Rest} when Len =< byte_size(Rest) ->
            <<Bytes:Len/binary, Tail/binary>> = Rest,
            {Bytes, Tail};
        _ ->
            error
    end.

%% ---------------------------------------------------------------------------
%% Pretty-printing
%% ---------------------------------------------------------------------------

-spec format_message(binary(), non_neg_integer()) -> iolist().
format_message(Bin, Depth) ->
    format_fields(Bin, Depth, 0, []).

-spec format_fields(binary(), non_neg_integer(), non_neg_integer(), iolist()) -> iolist().
format_fields(<<>>, _Depth, _Fields, Acc) ->
    lists:reverse(Acc);
format_fields(_Bin, Depth, Fields, Acc) when Fields >= ?MAX_FIELDS ->
    lists:reverse([[indent(Depth), "... more fields\n"] | Acc]);
format_fields(Bin, Depth, Fields, Acc) ->
    case consume_varint(Bin) of
        {Tag, Rest} ->
            Num = Tag bsr 3,
            Wt = Tag band 7,
            case format_field(Wt, Rest, Num, Depth) of
                {ok, Rest2, Line} ->
                    format_fields(Rest2, Depth, Fields + 1, [Line | Acc]);
                error ->
                    lists:reverse(Acc)
            end;
        error ->
            lists:reverse(Acc)
    end.

-spec format_field(non_neg_integer(), binary(), non_neg_integer(), non_neg_integer()) ->
    {ok, binary(), iolist()} | error.
format_field(0, Bin, Num, Depth) ->
    case consume_varint(Bin) of
        {V, Rest} -> {ok, Rest, [indent(Depth), int(Num), ": ", int(V), "\n"]};
        error -> error
    end;
format_field(1, <<V:64/little, Rest/binary>>, Num, Depth) ->
    {ok, Rest, [indent(Depth), int(Num), ": ", hex(V), "\n"]};
format_field(1, _, _, _) ->
    error;
format_field(2, Bin, Num, Depth) ->
    case consume_bytes(Bin) of
        {Bytes, Rest} -> {ok, Rest, format_bytes_field(Num, Bytes, Depth)};
        error -> error
    end;
format_field(5, <<V:32/little, Rest/binary>>, Num, Depth) ->
    {ok, Rest, [indent(Depth), int(Num), ": ", hex(V), "\n"]};
format_field(5, _, _, _) ->
    error;
format_field(_, _, _, _) ->
    error.

-spec format_bytes_field(non_neg_integer(), binary(), non_neg_integer()) -> iolist().
format_bytes_field(Num, Bytes, Depth) ->
    case is_printable_utf8(Bytes) of
        true ->
            [indent(Depth), int(Num), ": ", io_lib:format("~p", [Bytes]), "\n"];
        false ->
            case Depth < ?MAX_DEPTH andalso is_valid_protobuf(Bytes) of
                true ->
                    [indent(Depth), int(Num), ": {\n",
                     format_message(Bytes, Depth + 1),
                     indent(Depth), "}\n"];
                false ->
                    [indent(Depth), int(Num), ": <", int(byte_size(Bytes)), " bytes>\n"]
            end
    end.

-spec is_printable_utf8(binary()) -> boolean().
is_printable_utf8(<<>>) -> false;
is_printable_utf8(Bytes) ->
    case valid_utf8(Bytes) of
        false -> false;
        true -> printable_chars(unicode:characters_to_list(Bytes))
    end.

-spec valid_utf8(binary()) -> boolean().
valid_utf8(Bytes) ->
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        B when is_binary(B) -> true;
        _ -> false
    end.

-spec printable_chars([integer()]) -> boolean().
printable_chars([]) -> true;
printable_chars([$\t | T]) -> printable_chars(T);
printable_chars([$\n | T]) -> printable_chars(T);
printable_chars([$\r | T]) -> printable_chars(T);
printable_chars([C | T]) when C >= 32, C =/= 127 -> printable_chars(T);
printable_chars(_) -> false.

-spec indent(non_neg_integer()) -> iolist().
indent(0) -> [];
indent(Depth) -> lists:duplicate(Depth, "  ").

-spec int(integer()) -> iolist().
int(N) -> integer_to_list(N).

-spec hex(non_neg_integer()) -> iolist().
hex(V) -> ["0x", integer_to_list(V, 16)].

%% ---------------------------------------------------------------------------
%% Snappy / S2 block decoder
%% ---------------------------------------------------------------------------

%% @doc Decodes a Snappy/S2 block stream. Returns `error' on malformed input.
-spec snappy_decode(binary()) -> {ok, binary()} | error.
snappy_decode(Bin) ->
    case consume_varint(Bin) of
        {Len, Rest} ->
            case snappy_blocks(Rest, <<>>) of
                {ok, Out} when byte_size(Out) =:= Len -> {ok, Out};
                _ -> error
            end;
        error ->
            error
    end.

-spec snappy_blocks(binary(), binary()) -> {ok, binary()} | error.
snappy_blocks(<<>>, Acc) ->
    {ok, Acc};
snappy_blocks(<<Tag, Rest/binary>>, Acc) ->
    case Tag band 3 of
        0 ->
            case literal_len(Tag bsr 2, Rest) of
                {ok, Len, Rest1} when byte_size(Rest1) >= Len ->
                    <<Lit:Len/binary, Rest2/binary>> = Rest1,
                    snappy_blocks(Rest2, <<Acc/binary, Lit/binary>>);
                _ ->
                    error
            end;
        1 ->
            case Rest of
                <<Next, Rest1/binary>> ->
                    Len = ((Tag bsr 2) band 7) + 4,
                    Offset = ((Tag bsr 5) bsl 8) bor Next,
                    snappy_copy(Acc, Offset, Len, Rest1);
                _ ->
                    error
            end;
        2 ->
            case Rest of
                <<Off:16/little, Rest1/binary>> ->
                    Len = (Tag bsr 2) + 1,
                    snappy_copy(Acc, Off, Len, Rest1);
                _ ->
                    error
            end;
        3 ->
            case Rest of
                <<Off:32/little, Rest1/binary>> ->
                    Len = (Tag bsr 2) + 1,
                    snappy_copy(Acc, Off, Len, Rest1);
                _ ->
                    error
            end
    end.

-spec literal_len(non_neg_integer(), binary()) ->
    {ok, non_neg_integer(), binary()} | error.
literal_len(L, Rest) when L < 60 ->
    {ok, L + 1, Rest};
literal_len(L, Rest) ->
    Extra = L - 59,
    case byte_size(Rest) >= Extra of
        true ->
            LenBin = binary:part(Rest, 0, Extra),
            Rest1 = binary:part(Rest, Extra, byte_size(Rest) - Extra),
            {ok, binary:decode_unsigned(LenBin, little) + 1, Rest1};
        false ->
            error
    end.

-spec snappy_copy(binary(), non_neg_integer(), pos_integer(), binary()) ->
    {ok, binary()} | error.
snappy_copy(Acc, Offset, Len, Rest) ->
    Size = byte_size(Acc),
    case Offset > 0 andalso Offset =< Size of
        false ->
            error;
        true ->
            Pattern = binary:part(Acc, Size - Offset, Offset),
            Added = repeat_pattern(Pattern, Len),
            snappy_blocks(Rest, <<Acc/binary, Added/binary>>)
    end.

-spec repeat_pattern(binary(), non_neg_integer()) -> binary().
repeat_pattern(Pattern, Len) ->
    PLen = byte_size(Pattern),
    Times = Len div PLen,
    Rem = Len rem PLen,
    Base = binary:copy(Pattern, Times),
    <<Base/binary, (binary:part(Pattern, 0, Rem))/binary>>.
