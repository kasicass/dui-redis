%% @doc Small formatting helpers.
-module(dui_redis_fmt).

-export([
    screen_name/1,
    ttl/1,
    connection_label/1,
    join/2
]).

%% @doc Human-readable screen name.
-spec screen_name(atom()) -> binary().
screen_name(connections) -> <<"Connections">>;
screen_name(connection_form) -> <<"Connection">>;
screen_name(test_connection) -> <<"Test Connection">>;
screen_name(confirm_delete) -> <<"Confirm Delete">>;
screen_name(keys) -> <<"Keys">>;
screen_name(key_detail) -> <<"Key Detail">>;
screen_name(help) -> <<"Help">>;
screen_name(Other) -> atom_to_binary(Other, utf8).

%% @doc Formats a TTL in milliseconds.
-spec ttl(integer()) -> binary().
ttl(Ttl) when Ttl < 0 ->
    <<"no expiry">>;
ttl(0) ->
    <<"expired">>;
ttl(Ttl) ->
    iolist_to_binary(io_lib:format("~pms", [Ttl])).

%% @doc Formats a connection map as `Name (host:port)'.
-spec connection_label(map()) -> binary().
connection_label(Conn) ->
    Name = to_binary(maps:get(name, Conn, <<>>)),
    Host = to_binary(maps:get(host, Conn, <<>>)),
    Port = maps:get(port, Conn, 6379),
    HostPort = <<Host/binary, ":", (integer_to_binary(Port))/binary>>,
    case Name of
        <<>> -> HostPort;
        _ -> <<Name/binary, " (", HostPort/binary, ")">>
    end.

%% @doc Joins a list of binaries with `Sep'.
-spec join([binary()], binary()) -> binary().
join([], _Sep) ->
    <<>>;
join([H], _Sep) ->
    to_binary(H);
join([H | T], Sep) ->
    <<(to_binary(H))/binary, Sep/binary, (join(T, Sep))/binary>>.

-spec to_binary(term()) -> binary().
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
