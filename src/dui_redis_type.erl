%% @doc Pure Redis key-type helpers.
%%
%% Maps Redis `TYPE' strings to atoms, detects string subtypes (HyperLogLog,
%% bitmap) and geospatial sorted sets, and sorts key maps for display.
-module(dui_redis_type).

-export([
    to_type/1,
    is_utf8/1,
    detect_string_subtype/1,
    looks_like_geoscores/1,
    sort_keys/3
]).

%% @doc Converts a Redis `TYPE' reply to an atom.
-spec to_type(binary() | atom()) -> atom().
to_type(<<"string">>) -> string;
to_type(<<"list">>) -> list;
to_type(<<"set">>) -> set;
to_type(<<"zset">>) -> zset;
to_type(<<"hash">>) -> hash;
to_type(<<"stream">>) -> stream;
to_type(<<"ReJSON-RL">>) -> json;
to_type(<<"none">>) -> none;
to_type(Other) when is_binary(Other) -> string;
to_type(Other) when is_atom(Other) -> Other.

%% @doc True if `Bin' is valid UTF-8.
-spec is_utf8(binary()) -> boolean().
is_utf8(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        B when is_binary(B) -> true;
        _ -> false
    end.

%% @doc Classifies a string value as `string', `hll' or `bitmap'.
-spec detect_string_subtype(binary()) -> string | hll | bitmap.
detect_string_subtype(<<"HYLL", _/binary>>) ->
    hll;
detect_string_subtype(<<>>) ->
    string;
detect_string_subtype(Bin) ->
    case is_utf8(Bin) of
        true -> string;
        false -> bitmap
    end.

%% @doc True if all scores look like 52-bit geohash integers produced by GEOADD.
-spec looks_like_geoscores([number()]) -> boolean().
looks_like_geoscores([]) ->
    false;
looks_like_geoscores(Scores) ->
    lists:all(
        fun(S) ->
            S >= 1.0e14 andalso S =< 5.0e15 andalso S == trunc(S)
        end,
        Scores).

%% @doc Sorts key maps by `key', `type' or `ttl', ascending or descending.
-spec sort_keys([map()], key | type | ttl, boolean()) -> [map()].
sort_keys(Keys, By, Asc) ->
    Sorted = lists:sort(fun(A, B) -> compare(By, A, B) end, Keys),
    case Asc of
        true -> Sorted;
        false -> lists:reverse(Sorted)
    end.

%% ---------------------------------------------------------------------------

-spec compare(key | type | ttl, map(), map()) -> boolean().
compare(key, A, B) ->
    maps:get(key, A, <<>>) =< maps:get(key, B, <<>>);
compare(type, A, B) ->
    {maps:get(type, A, string), maps:get(key, A, <<>>)}
        =< {maps:get(type, B, string), maps:get(key, B, <<>>)};
compare(ttl, A, B) ->
    {ttl_sort(A), maps:get(key, A, <<>>)} =< {ttl_sort(B), maps:get(key, B, <<>>)}.

-spec ttl_sort(map()) -> integer().
ttl_sort(Key) ->
    case maps:get(ttl, Key, -1) of
        T when T > 0 -> T;
        _ -> 16#7FFFFFFFFFFFFFFF
    end.
