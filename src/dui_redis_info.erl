%% @doc Parses Redis `INFO' output into a flat key/value map.
%%
%% INFO is a sequence of `key:value' lines grouped under `# Section' headers.
%% This module is pure so it can be unit-tested without a server.
-module(dui_redis_info).

-export([parse/1, get/2, get/3, int/2, float/2, sections/1]).

%% @doc Parses INFO text into `#{<<"key">> => <<"value">>}'.
-spec parse(binary()) -> map().
parse(Bin) when is_binary(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    lists:foldl(fun parse_line/2, #{}, Lines).

%% @doc Looks up a field by name (binary key), with an optional default.
-spec get(binary(), map()) -> binary() | undefined.
get(Key, Info) -> maps:get(Key, Info, undefined).

-spec get(binary(), map(), binary()) -> binary().
get(Key, Info, Default) -> maps:get(Key, Info, Default).

%% @doc Parses an integer field, returning `Default' on failure.
-spec int(binary(), map()) -> integer() | undefined.
int(Key, Info) ->
    case get(Key, Info) of
        undefined -> undefined;
        V -> to_int(V)
    end.

%% @doc Parses a float field, returning `undefined' on failure.
-spec float(binary(), map()) -> float() | undefined.
float(Key, Info) ->
    case get(Key, Info) of
        undefined -> undefined;
        V -> to_float(V)
    end.

%% @doc Returns the list of section names in order.
-spec sections(binary()) -> [binary()].
sections(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    lists:filtermap(
        fun(Line) ->
            case section(trim(Line)) of
                {ok, Name} -> {true, Name};
                skip -> false
            end
        end,
        Lines).

%% ---------------------------------------------------------------------------

-spec parse_line(binary(), map()) -> map().
parse_line(Line0, Acc) ->
    Line = trim(Line0),
    case Line of
        <<>> -> Acc;
        <<"#", _/binary>> -> Acc;
        _ ->
            case binary:split(Line, <<":">>) of
                [Key, Value] -> maps:put(Key, Value, Acc);
                _ -> Acc
            end
    end.

-spec section(binary()) -> {ok, binary()} | skip.
section(<<"#", Rest/binary>>) -> {ok, trim(Rest)};
section(_) -> skip.

-spec trim(binary()) -> binary().
trim(Bin) ->
    string:trim(Bin, both, [$\s, $\t, $\r, $\n]).

-spec to_int(binary()) -> integer() | undefined.
to_int(V) ->
    try binary_to_integer(V)
    catch error:badarg -> undefined
    end.

-spec to_float(binary()) -> float() | undefined.
to_float(V) ->
    try binary_to_float(V)
    catch error:badarg ->
        try binary_to_integer(V) * 1.0
        catch error:badarg -> undefined
        end
    end.
