%% @doc Pure conversion between bounded value maps and the JSON export format.
%%
%% Export shape (mirrors redis-tui):
%% ```
%% {"key": {"type": "string", "ttl": 3600, "value": "..."},
%%  "list": {"type": "list", "ttl": -1, "value": ["a", "b"]}}
%% '''
-module(dui_redis_export).

-export([encode/2, decode/1]).

%% @doc Builds the JSON-ready map for a value.
-spec encode(map(), integer()) -> map().
encode(Value, Ttl) ->
    #{<<"type">> => type_bin(maps:get(type, Value, string)),
      <<"ttl">> => Ttl,
      <<"value">> => encode_value(Value)}.

%% @doc Decodes a JSON export entry into `{Type, Value, Ttl}'.
-spec decode(map()) -> {atom(), term(), integer()} | error.
decode(Meta) when is_map(Meta) ->
    TypeBin = get_any(<<"type">>, Meta, <<"string">>),
    Ttl = to_int(get_any(<<"ttl">>, Meta, -1), -1),
    Value = get_any(<<"value">>, Meta, <<>>),
    {dui_redis_type:to_type(TypeBin), Value, Ttl};
decode(_) ->
    error.

%% ---------------------------------------------------------------------------

-spec encode_value(map()) -> term().
encode_value(#{type := string} = V) -> maps:get(text, V, <<>>);
encode_value(#{type := json} = V) -> maps:get(text, V, <<>>);
encode_value(#{type := hll} = V) -> maps:get(text, V, <<>>);
encode_value(#{type := bitmap} = V) -> maps:get(text, V, <<>>);
encode_value(#{type := list} = V) -> maps:get(items, V, []);
encode_value(#{type := set} = V) -> maps:get(items, V, []);
encode_value(#{type := zset} = V) ->
    [#{<<"member">> => M, <<"score">> => S} || {M, S} <- maps:get(items, V, [])];
encode_value(#{type := geo} = V) ->
    [#{<<"member">> => M, <<"lon">> => Lon, <<"lat">> => Lat}
     || {M, Lon, Lat} <- maps:get(items, V, [])];
encode_value(#{type := hash} = V) ->
    maps:from_list([{F, Val} || {F, Val} <- maps:get(items, V, [])]);
encode_value(#{type := stream} = V) ->
    [#{<<"id">> => Id, <<"fields">> => maps:from_list(Fields)}
     || {Id, Fields} <- maps:get(items, V, [])];
encode_value(_) -> <<>>.

-spec type_bin(atom()) -> binary().
type_bin(Type) -> atom_to_binary(Type, utf8).

-spec get_any(binary(), map(), term()) -> term().
get_any(Key, Map, Default) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error ->
            case atom_key(Key) of
                undefined -> Default;
                Atom -> maps:get(Atom, Map, Default)
            end
    end.

-spec atom_key(binary()) -> atom() | undefined.
atom_key(Key) ->
    try binary_to_existing_atom(Key, utf8)
    catch error:badarg -> undefined
    end.

-spec to_int(term(), integer()) -> integer().
to_int(N, _Default) when is_integer(N) -> N;
to_int(N, _Default) when is_float(N) -> trunc(N);
to_int(B, Default) when is_binary(B) ->
    try binary_to_integer(B) catch error:badarg -> Default end;
to_int(_, Default) -> Default.
