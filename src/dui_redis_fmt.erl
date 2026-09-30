%% @doc Small formatting helpers.
-module(dui_redis_fmt).

-export([
    screen_name/1,
    ttl/1,
    ttl_render/1,
    type_render/1,
    duration/1,
    bytes/1,
    bool/1,
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
screen_name(edit_value) -> <<"Edit Value">>;
screen_name(prompt) -> <<"Input">>;
screen_name(results) -> <<"Results">>;
screen_name(tree) -> <<"Tree View">>;
screen_name(result_text) -> <<"Result">>;
screen_name(server_info) -> <<"Server Info">>;
screen_name(slow_log) -> <<"Slow Log">>;
screen_name(client_list) -> <<"Clients">>;
screen_name(memory_stats) -> <<"Memory Stats">>;
screen_name(live_metrics) -> <<"Live Metrics">>;
screen_name(expiring_keys) -> <<"Expiring Keys">>;
screen_name(logs) -> <<"Logs">>;
screen_name(switch_db) -> <<"Switch Database">>;
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

%% @doc Formats a Redis TTL in seconds for display.
-spec ttl_render(integer()) -> binary().
ttl_render(-1) -> <<"no expiry">>;
ttl_render(-2) -> <<"expired">>;
ttl_render(S) when S > 0 -> <<(integer_to_binary(S))/binary, "s">>;
ttl_render(_) -> <<>>.

%% @doc Formats a duration in seconds as e.g. `1d 2h 3m'.
-spec duration(non_neg_integer()) -> binary().
duration(Seconds) when is_integer(Seconds), Seconds >= 0 ->
    D = Seconds div 86400,
    H = (Seconds rem 86400) div 3600,
    M = (Seconds rem 3600) div 60,
    S = Seconds rem 60,
    Parts = [{D, <<"d">>}, {H, <<"h">>}, {M, <<"m">>}, {S, <<"s">>}],
    NonZero = [<<(integer_to_binary(N))/binary, U/binary>>
               || {N, U} <- Parts, N > 0],
    case NonZero of
        [] -> <<"0s">>;
        _ -> iolist_to_binary(lists:join(<<" ">>, NonZero))
    end.

%% @doc Formats a byte count as a human-readable string.
-spec bytes(integer()) -> binary().
bytes(B) when B >= 1073741824 ->
    iolist_to_binary(io_lib:format("~.2f GB", [B / 1073741824]));
bytes(B) when B >= 1048576 ->
    iolist_to_binary(io_lib:format("~.2f MB", [B / 1048576]));
bytes(B) when B >= 1024 ->
    iolist_to_binary(io_lib:format("~.2f KB", [B / 1024]));
bytes(B) -> <<(integer_to_binary(B))/binary, " B">>.

%% @doc Boolean display helper.
-spec bool(boolean()) -> binary().
bool(true) -> <<"yes">>;
bool(false) -> <<"no">>.

%% @doc Human-readable key type.
-spec type_render(atom()) -> binary().
type_render(Type) ->
    dui_redis_preview:type_label(Type).

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
