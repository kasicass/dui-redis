%% @doc Pure parsers for `CLUSTER NODES' and `CLUSTER INFO'.
-module(dui_redis_cluster).

-export([parse_nodes/1, parse_info/1]).

%% @doc Parses `CLUSTER NODES' output into a list of node maps.
-spec parse_nodes(binary()) -> [map()].
parse_nodes(Bin) when is_binary(Bin) ->
    Lines = [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>],
    [parse_node(L) || L <- Lines].

%% @doc Parses `CLUSTER INFO' (`key:value' lines) into a map.
-spec parse_info(binary()) -> map().
parse_info(Bin) when is_binary(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    lists:foldl(
        fun(Line, Acc) ->
            case binary:split(string:trim(Line), <<":">>) of
                [K, V] -> maps:put(K, V, Acc);
                _ -> Acc
            end
        end,
        #{}, Lines).

%% ---------------------------------------------------------------------------

-spec parse_node(binary()) -> map().
parse_node(Line) ->
    case binary:split(string:trim(Line), <<" ">>, [global, trim_all]) of
        [Id, Addr, Flags, Master, Ping, Pong, Epoch, Link | Slots] ->
            #{id => Id, addr => Addr, flags => Flags, master => Master,
              ping => to_int(Ping), pong => to_int(Pong), epoch => to_int(Epoch),
              link => Link, slots => Slots,
              role => role(Flags)};
        _ ->
            #{}
    end.

-spec role(binary()) -> binary().
role(Flags) ->
    case binary:match(Flags, <<"master">>) of
        nomatch -> <<"replica">>;
        _ -> <<"master">>
    end.

-spec to_int(binary()) -> integer().
to_int(B) ->
    try binary_to_integer(B) catch error:badarg -> 0 end.
