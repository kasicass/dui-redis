%% @doc Redis client wrapper around eredis.
%%
%% A single registered gen_server owns the active connection. All calls are
%% safe when the client is not running (they return `{error, no_client}'), so
%% application code never crashes on a missing process.
%%
%% Supports standalone connections; cluster mode is reported as unsupported
%% until M6. Key/value reads are bounded (preview: 100 items / 64 KB) so a
%% huge key never blocks the UI or transfers megabytes.
-module(dui_redis_client).

-behaviour(gen_server).

-export([
    start_link/0,
    connect/1, disconnect/0, test/1, select_db/1,
    ping/0, q/1, q/2, is_connected/0, current/0,
    scan_keys/3, value_preview/1, value_detail/1, db_size/0,
    set_string/3, delete_key/1, rename_key/2, copy_key/3, set_ttl/2,
    flush_db/0, list_push/2, list_set/3, list_remove/2,
    set_add/2, set_remove/2, zset_add/3, zset_remove/2,
    hash_set/3, hash_delete/2, stream_add/2, stream_delete/2,
    json_set/2, memory_usage/1, key_ttl/1,
    scan_regex/2, fuzzy_search/2, search_by_value/3, compare_keys/2, json_get_path/2,
    build_options/1, stop/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(CALL_TIMEOUT, 15000).
-define(SCAN_TIMEOUT, 20000).
-define(PREVIEW_MAX_ITEMS, 100).
-define(PREVIEW_MAX_BYTES, 65536).
-define(DETAIL_MAX_ITEMS, 1000).
-define(DETAIL_MAX_BYTES, 1048576).
-define(PROBE_BYTES, 256).

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Connects to the Redis instance described by `Conn'.
-spec connect(map()) -> ok | {error, term()}.
connect(Conn) -> call({connect, Conn}).

%% @doc Closes the active connection.
-spec disconnect() -> ok.
disconnect() -> call(disconnect).

%% @doc Opens a temporary connection, PINGs it, and closes it.
-spec test(map()) -> {ok, non_neg_integer()} | {error, term()}.
test(Conn) -> call({test, Conn}).

%% @doc Switches the active database (standalone only).
-spec select_db(integer()) -> ok | {error, term()}.
select_db(Db) -> call({select_db, Db}).

%% @doc PINGs the active connection.
-spec ping() -> {ok, term()} | {error, term()}.
ping() -> q([<<"PING">>]).

%% @doc Runs a command on the active connection.
-spec q([term()]) -> {ok, term()} | {error, term()}.
q(Command) -> call({q, Command}).

%% @doc Runs a command with a custom timeout.
-spec q([term()], timeout()) -> {ok, term()} | {error, term()}.
q(Command, Timeout) -> call({q, Command}, Timeout).

-spec is_connected() -> boolean().
is_connected() -> call(is_connected).

%% @doc Returns the currently connected config map, if any.
-spec current() -> {ok, map()} | undefined.
current() -> call(current).

%% @doc SCANs keys, enriching each with TYPE and TTL. Returns
%% `{ok, #{keys := [map()], cursor := integer(), total := integer()}}'.
-spec scan_keys(binary(), integer(), integer()) -> {ok, map()} | {error, term()}.
scan_keys(Pattern, Cursor, Count) ->
    call({scan_keys, Pattern, Cursor, Count}, ?SCAN_TIMEOUT).

%% @doc Returns a bounded preview of the value at `Key'.
-spec value_preview(binary()) -> {ok, map()} | {error, term()}.
value_preview(Key) -> call({value_preview, Key}, ?SCAN_TIMEOUT).

%% @doc Returns a larger bounded value for the detail screen (1000 items / 1 MB).
-spec value_detail(binary()) -> {ok, map()} | {error, term()}.
value_detail(Key) -> call({value_detail, Key}, ?SCAN_TIMEOUT).

%% @doc Returns the number of keys in the current database.
-spec db_size() -> {ok, non_neg_integer()} | {error, term()}.
db_size() -> call(db_size).

%% @doc SETs a string value, optionally with a TTL in seconds.
-spec set_string(binary(), binary(), integer()) -> {ok, term()} | {error, term()}.
set_string(Key, Value, TtlSeconds) ->
    Cmd = case TtlSeconds of
        T when is_integer(T), T > 0 ->
            [<<"SET">>, Key, Value, <<"EX">>, integer_to_binary(T)];
        _ ->
            [<<"SET">>, Key, Value]
    end,
    q(Cmd).

-spec delete_key(binary()) -> {ok, term()} | {error, term()}.
delete_key(Key) -> q([<<"DEL">>, Key]).

-spec rename_key(binary(), binary()) -> {ok, term()} | {error, term()}.
rename_key(OldKey, NewKey) -> q([<<"RENAME">>, OldKey, NewKey]).

-spec copy_key(binary(), binary(), boolean()) -> {ok, term()} | {error, term()}.
copy_key(Src, Dst, Replace) ->
    Cmd = case Replace of
        true -> [<<"COPY">>, Src, Dst, <<"REPLACE">>];
        false -> [<<"COPY">>, Src, Dst]
    end,
    q(Cmd).

-spec set_ttl(binary(), integer()) -> {ok, term()} | {error, term()}.
set_ttl(Key, Seconds) when is_integer(Seconds), Seconds > 0 ->
    q([<<"EXPIRE">>, Key, integer_to_binary(Seconds)]);
set_ttl(Key, _Seconds) ->
    q([<<"PERSIST">>, Key]).

-spec flush_db() -> {ok, term()} | {error, term()}.
flush_db() -> q([<<"FLUSHDB">>]).

-spec list_push(binary(), binary()) -> {ok, term()} | {error, term()}.
list_push(Key, Value) -> q([<<"RPUSH">>, Key, Value]).

-spec list_set(binary(), integer(), binary()) -> {ok, term()} | {error, term()}.
list_set(Key, Index, Value) -> q([<<"LSET">>, Key, integer_to_binary(Index), Value]).

-spec list_remove(binary(), binary()) -> {ok, term()} | {error, term()}.
list_remove(Key, Value) -> q([<<"LREM">>, Key, <<"1">>, Value]).

-spec set_add(binary(), binary()) -> {ok, term()} | {error, term()}.
set_add(Key, Member) -> q([<<"SADD">>, Key, Member]).

-spec set_remove(binary(), binary()) -> {ok, term()} | {error, term()}.
set_remove(Key, Member) -> q([<<"SREM">>, Key, Member]).

-spec zset_add(binary(), number(), binary()) -> {ok, term()} | {error, term()}.
zset_add(Key, Score, Member) -> q([<<"ZADD">>, Key, number_bin(Score), Member]).

-spec zset_remove(binary(), binary()) -> {ok, term()} | {error, term()}.
zset_remove(Key, Member) -> q([<<"ZREM">>, Key, Member]).

-spec hash_set(binary(), binary(), binary()) -> {ok, term()} | {error, term()}.
hash_set(Key, Field, Value) -> q([<<"HSET">>, Key, Field, Value]).

-spec hash_delete(binary(), binary()) -> {ok, term()} | {error, term()}.
hash_delete(Key, Field) -> q([<<"HDEL">>, Key, Field]).

-spec stream_add(binary(), [{term(), term()}]) -> {ok, term()} | {error, term()}.
stream_add(Key, Fields) -> q([<<"XADD">>, Key, <<"*">> | flat_fields(Fields)]).

-spec stream_delete(binary(), binary()) -> {ok, term()} | {error, term()}.
stream_delete(Key, Id) -> q([<<"XDEL">>, Key, Id]).

-spec json_set(binary(), binary()) -> {ok, term()} | {error, term()}.
json_set(Key, Value) -> q([<<"JSON.SET">>, Key, <<"$">>, Value]).

-spec memory_usage(binary()) -> {ok, term()} | {error, term()}.
memory_usage(Key) -> q([<<"MEMORY">>, <<"USAGE">>, Key]).

-spec key_ttl(binary()) -> {ok, term()} | {error, term()}.
key_ttl(Key) -> q([<<"TTL">>, Key]).

%% @doc Returns keys matching a regex (bounded to `Max').
-spec scan_regex(binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
scan_regex(Pattern, Max) -> call({scan_regex, Pattern, Max}, ?SCAN_TIMEOUT).

%% @doc Returns the top `Max' keys by fuzzy score against `Term'.
-spec fuzzy_search(binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
fuzzy_search(Term, Max) -> call({fuzzy_search, Term, Max}, ?SCAN_TIMEOUT).

%% @doc Returns keys whose bounded value contains `ValueSearch'.
-spec search_by_value(binary(), binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
search_by_value(Pattern, ValueSearch, Max) ->
    call({search_by_value, Pattern, ValueSearch, Max}, ?SCAN_TIMEOUT).

%% @doc Returns `{Key1Value, Key2Value, Diff}' for two keys.
-spec compare_keys(binary(), binary()) -> {ok, {map(), map(), binary()}} | {error, term()}.
compare_keys(Key1, Key2) -> call({compare_keys, Key1, Key2}, ?SCAN_TIMEOUT).

%% @doc Runs JSON.GET with an explicit path.
-spec json_get_path(binary(), binary()) -> {ok, term()} | {error, term()}.
json_get_path(Key, Path) -> q([<<"JSON.GET">>, Key, Path]).

-spec stop() -> ok.
stop() -> gen_server:stop(?SERVER).

%% ---------------------------------------------------------------------------
%% Option building (pure, unit-testable)
%% ---------------------------------------------------------------------------

%% @doc Builds eredis options (a proplist) from a connection map.
-spec build_options(map()) -> [term()].
build_options(Conn) ->
    Base = [{host, to_list(maps:get(host, Conn, <<"127.0.0.1">>))},
            {port, maps:get(port, Conn, 6379)},
            {database, maps:get(db, Conn, 0)},
            {connect_timeout, 5000}],
    WithUser = put_optional(username, maps:get(username, Conn, undefined), Base),
    WithPass = put_optional(password, maps:get(password, Conn, undefined), WithUser),
    case maps:get(use_tls, Conn, false) of
        true ->
            [{tls, tls_options(maps:get(tls_config, Conn, #{}))} | WithPass];
        false ->
            WithPass
    end.

%% ---------------------------------------------------------------------------
%% gen_server
%% ---------------------------------------------------------------------------

-spec init([]) -> {ok, map()}.
init([]) ->
    process_flag(trap_exit, true),
    {ok, #{conn => undefined, conn_config => undefined}}.

handle_call({connect, Conn}, _From, State) ->
    State1 = do_disconnect(State),
    case maps:get(use_cluster, Conn, false) of
        true ->
            {reply, {error, cluster_not_supported}, State1};
        false ->
            do_connect(Conn, State1)
    end;
handle_call(disconnect, _From, State) ->
    {reply, ok, do_disconnect(State)};
handle_call({test, Conn}, _From, State) ->
    {reply, do_test(Conn), State};
handle_call({select_db, Db}, _From, State) ->
    {reply, do_select_db(Db, State), State};
handle_call({q, Command}, _From, State) ->
    {reply, do_q(Command, State), State};
handle_call(is_connected, _From, State) ->
    {reply, maps:get(conn, State) =/= undefined, State};
handle_call(current, _From, State) ->
    case maps:get(conn_config, State, undefined) of
        undefined -> {reply, undefined, State};
        Conn -> {reply, {ok, Conn}, State}
    end;
handle_call({scan_keys, Pattern, Cursor, Count}, _From, State) ->
    {reply, with_conn(State, fun(Pid) -> do_scan_keys(Pid, Pattern, Cursor, Count) end), State};
handle_call({value_preview, Key}, _From, State) ->
    {reply, with_conn(State, fun(Pid) -> do_value_preview(Pid, Key) end), State};
handle_call({value_detail, Key}, _From, State) ->
    {reply, with_conn(State, fun(Pid) -> do_value_detail(Pid, Key) end), State};
handle_call(db_size, _From, State) ->
    {reply, with_conn(State, fun do_db_size/1), State};
handle_call({scan_regex, Pattern, Max}, _From, State) ->
    {reply, with_conn(State, fun(Pid) -> do_scan_regex(Pid, Pattern, Max) end), State};
handle_call({fuzzy_search, Term, Max}, _From, State) ->
    {reply, with_conn(State, fun(Pid) -> do_fuzzy_search(Pid, Term, Max) end), State};
handle_call({search_by_value, Pattern, Search, Max}, _From, State) ->
    {reply, with_conn(State, fun(Pid) -> do_search_by_value(Pid, Pattern, Search, Max) end), State};
handle_call({compare_keys, Key1, Key2}, _From, State) ->
    {reply, with_conn(State, fun(Pid) -> do_compare_keys(Pid, Key1, Key2) end), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, _Reason}, #{conn := Pid} = State) ->
    {noreply, State#{conn := undefined, conn_config := undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = do_disconnect(State),
    ok.

%% ---------------------------------------------------------------------------
%% Connection helpers
%% ---------------------------------------------------------------------------

-spec call(term()) -> term().
call(Request) -> call(Request, ?CALL_TIMEOUT).

-spec call(term(), timeout()) -> term().
call(Request, Timeout) ->
    case whereis(?SERVER) of
        undefined -> {error, no_client};
        _ -> gen_server:call(?SERVER, Request, Timeout)
    end.

-spec with_conn(map(), fun((pid()) -> T)) -> T | {error, term()}.
with_conn(#{conn := Pid}, Fun) when is_pid(Pid) ->
    try Fun(Pid)
    catch Class:Reason -> {error, {Class, Reason}}
    end;
with_conn(_State, _Fun) ->
    {error, not_connected}.

-spec do_connect(map(), map()) -> {reply, ok | {error, term()}, map()}.
do_connect(Conn, State) ->
    case start_eredis(build_options(Conn)) of
        {ok, Pid} ->
            case eredis:q(Pid, [<<"PING">>]) of
                {ok, <<"PONG">>} ->
                    {reply, ok, State#{conn => Pid, conn_config => Conn}};
                {ok, Other} ->
                    _ = safe_stop(Pid),
                    {reply, {error, {unexpected_reply, Other}}, State};
                {error, Reason} ->
                    _ = safe_stop(Pid),
                    {reply, {error, Reason}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

-spec do_test(map()) -> {ok, non_neg_integer()} | {error, term()}.
do_test(Conn) ->
    Start = erlang:monotonic_time(millisecond),
    case start_eredis(build_options(Conn)) of
        {ok, Pid} ->
            Result = eredis:q(Pid, [<<"PING">>]),
            _ = safe_stop(Pid),
            case Result of
                {ok, <<"PONG">>} -> {ok, erlang:monotonic_time(millisecond) - Start};
                {ok, Other} -> {error, {unexpected_reply, Other}};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec start_eredis([term()]) -> {ok, pid()} | {error, term()}.
start_eredis(Options) ->
    try eredis:start_link(Options) of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

-spec safe_stop(pid()) -> ok.
safe_stop(Pid) ->
    _ = catch eredis:stop(Pid),
    ok.

-spec do_select_db(integer(), map()) -> ok | {error, term()}.
do_select_db(Db, #{conn := Pid}) when is_pid(Pid) ->
    case eredis:q(Pid, [<<"SELECT">>, integer_to_binary(Db)]) of
        {ok, <<"OK">>} -> ok;
        {ok, _Other} -> ok;
        {error, Reason} -> {error, Reason}
    end;
do_select_db(_Db, _State) ->
    {error, not_connected}.

-spec do_q([term()], map()) -> {ok, term()} | {error, term()}.
do_q(Command, #{conn := Pid}) when is_pid(Pid) ->
    eredis:q(Pid, Command);
do_q(_Command, _State) ->
    {error, not_connected}.

-spec do_disconnect(map()) -> map().
do_disconnect(#{conn := Pid} = State) when is_pid(Pid) ->
    _ = catch eredis:stop(Pid),
    State#{conn := undefined, conn_config := undefined};
do_disconnect(State) ->
    State.

-spec put_optional(atom(), term(), [term()]) -> [term()].
put_optional(_Key, undefined, Options) -> Options;
put_optional(_Key, <<>>, Options) -> Options;
put_optional(Key, Value, Options) -> [{Key, Value} | Options].

-spec tls_options(map()) -> [term()].
tls_options(Cfg) ->
    Opts0 = [],
    Opts1 = maybe_file(cacertfile, ca_file, Cfg, Opts0),
    Opts2 = maybe_file(certfile, cert_file, Cfg, Opts1),
    Opts3 = maybe_file(keyfile, key_file, Cfg, Opts2),
    case maps:get(insecure_skip_verify, Cfg, false) of
        true -> [{verify, verify_none} | Opts3];
        false -> Opts3
    end.

-spec maybe_file(atom(), atom(), map(), [term()]) -> [term()].
maybe_file(SslKey, CfgKey, Cfg, Acc) ->
    case maps:get(CfgKey, Cfg, undefined) of
        undefined -> Acc;
        <<>> -> Acc;
        Path -> [{SslKey, to_list(Path)} | Acc]
    end.

-spec to_list(term()) -> string().
to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(I) when is_integer(I) -> integer_to_list(I).

%% ---------------------------------------------------------------------------
%% Key scanning
%% ---------------------------------------------------------------------------

-spec do_scan_keys(pid(), binary(), integer(), integer()) -> {ok, map()} | {error, term()}.
do_scan_keys(Pid, Pattern, Cursor, Count) ->
    Cmd = [<<"SCAN">>, integer_to_binary(Cursor), <<"MATCH">>, Pattern,
           <<"COUNT">>, integer_to_binary(Count)],
    case eredis:q(Pid, Cmd) of
        {ok, [NextBin, KeyBins]} ->
            Keys0 = [#{key => K, type => string, ttl => -1} || K <- KeyBins],
            Keys1 = fill_type_ttl(Pid, Keys0),
            Keys2 = detect_string_subtypes(Pid, detect_zset_subtypes(Pid, Keys1)),
            Total = case do_db_size(Pid) of {ok, N} -> N; _ -> 0 end,
            {ok, #{keys => Keys2, cursor => to_int(NextBin, 0), total => Total}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec fill_type_ttl(pid(), [map()]) -> [map()].
fill_type_ttl(_Pid, []) ->
    [];
fill_type_ttl(Pid, Keys) ->
    Cmds = lists:flatmap(
        fun(#{key := K}) -> [[<<"TYPE">>, K], [<<"TTL">>, K]] end, Keys),
    case eredis:qp(Pid, Cmds) of
        Results when is_list(Results) ->
            Values = [case R of {ok, V} -> V; _ -> undefined end || R <- Results],
            Pairs = pair_up(Values),
            lists:zipwith(
                fun(Key, {TypeBin, TtlBin}) ->
                    Key#{type => dui_redis_type:to_type(TypeBin),
                         ttl => to_int(TtlBin, -1)}
                end,
                Keys, Pairs);
        _ ->
            Keys
    end.

-spec detect_string_subtypes(pid(), [map()]) -> [map()].
detect_string_subtypes(Pid, Keys) ->
    Names = [maps:get(key, K) || K <- Keys, maps:get(type, K, undefined) =:= string],
    case Names of
        [] ->
            Keys;
        _ ->
            Cmds = [[<<"GETRANGE">>, N, <<"0">>, integer_to_binary(?PROBE_BYTES - 1)] || N <- Names],
            case eredis:qp(Pid, Cmds) of
                Results when is_list(Results) ->
                    Probing = maps:from_list(
                        lists:zip(Names, [probe(R) || R <- Results])),
                    [maybe_string_subtype(K, Probing) || K <- Keys];
                _ ->
                    Keys
            end
    end.

-spec maybe_string_subtype(map(), map()) -> map().
maybe_string_subtype(#{type := string, key := Name} = K, Probing) ->
    case maps:get(Name, Probing, undefined) of
        undefined -> K;
        Bin -> K#{type => dui_redis_type:detect_string_subtype(Bin)}
    end;
maybe_string_subtype(K, _Probing) ->
    K.

-spec detect_zset_subtypes(pid(), [map()]) -> [map()].
detect_zset_subtypes(Pid, Keys) ->
    Names = [maps:get(key, K) || K <- Keys, maps:get(type, K, undefined) =:= zset],
    case Names of
        [] ->
            Keys;
        _ ->
            Cmds = [[<<"ZRANGE">>, N, <<"0">>, <<"0">>, <<"WITHSCORES">>] || N <- Names],
            case eredis:qp(Pid, Cmds) of
                Results when is_list(Results) ->
                    Scores = maps:from_list(lists:zip(Names, [zscore(R) || R <- Results])),
                    [maybe_zset_subtype(K, Scores) || K <- Keys];
                _ ->
                    Keys
            end
    end.

-spec maybe_zset_subtype(map(), map()) -> map().
maybe_zset_subtype(#{type := zset, key := Name} = K, Scores) ->
    case maps:get(Name, Scores, undefined) of
        undefined -> K;
        S when is_float(S) ->
            case dui_redis_type:looks_like_geoscores([S]) of
                true -> K#{type => geo};
                false -> K
            end;
        _ -> K
    end;
maybe_zset_subtype(K, _Scores) ->
    K.

-spec probe(term()) -> binary() | undefined.
probe({ok, V}) when is_binary(V) -> V;
probe(_) -> undefined.

-spec zscore(term()) -> float() | undefined.
zscore({ok, [_Member, Score]}) -> to_float(Score);
zscore(_) -> undefined.

%% ---------------------------------------------------------------------------
%% Value preview
%% ---------------------------------------------------------------------------

-spec do_value_preview(pid(), binary()) -> {ok, map()} | {error, term()}.
do_value_preview(Pid, Key) ->
    fetch_bounded(Pid, Key, ?PREVIEW_MAX_ITEMS, ?PREVIEW_MAX_BYTES).

-spec do_value_detail(pid(), binary()) -> {ok, map()} | {error, term()}.
do_value_detail(Pid, Key) ->
    fetch_bounded(Pid, Key, ?DETAIL_MAX_ITEMS, ?DETAIL_MAX_BYTES).

-spec fetch_bounded(pid(), binary(), pos_integer(), pos_integer()) ->
    {ok, map()} | {error, term()}.
fetch_bounded(Pid, Key, MaxItems, MaxBytes) ->
    case eredis:q(Pid, [<<"TYPE">>, Key]) of
        {ok, TypeBin} ->
            fetch_value(Pid, Key, dui_redis_type:to_type(TypeBin), MaxItems, MaxBytes);
        {error, Reason} ->
            {error, Reason}
    end.

-spec fetch_value(pid(), binary(), atom(), pos_integer(), pos_integer()) ->
    {ok, map()} | {error, term()}.
fetch_value(_Pid, _Key, none, _MaxItems, _MaxBytes) ->
    {ok, #{type => none}};
fetch_value(Pid, Key, string, _MaxItems, MaxBytes) ->
    fetch_string(Pid, Key, MaxBytes);
fetch_value(Pid, Key, list, MaxItems, _MaxBytes) ->
    fetch_list(Pid, Key, MaxItems);
fetch_value(Pid, Key, set, MaxItems, _MaxBytes) ->
    fetch_set(Pid, Key, MaxItems);
fetch_value(Pid, Key, zset, MaxItems, _MaxBytes) ->
    fetch_zset(Pid, Key, MaxItems);
fetch_value(Pid, Key, geo, MaxItems, _MaxBytes) ->
    fetch_zset(Pid, Key, MaxItems);
fetch_value(Pid, Key, hash, MaxItems, _MaxBytes) ->
    fetch_hash(Pid, Key, MaxItems);
fetch_value(Pid, Key, stream, MaxItems, _MaxBytes) ->
    fetch_stream(Pid, Key, MaxItems);
fetch_value(Pid, Key, json, _MaxItems, _MaxBytes) ->
    fetch_json(Pid, Key);
fetch_value(_Pid, _Key, Type, _MaxItems, _MaxBytes) ->
    {ok, #{type => Type}}.

-spec fetch_string(pid(), binary(), pos_integer()) -> {ok, map()} | {error, term()}.
fetch_string(Pid, Key, MaxBytes) ->
    Total = to_int(q_val(Pid, [<<"STRLEN">>, Key]), 0),
    case eredis:q(Pid, [<<"GETRANGE">>, Key, <<"0">>, integer_to_binary(MaxBytes - 1)]) of
        {ok, Bin} ->
            Truncated = Total > byte_size(Bin),
            Type = dui_redis_type:detect_string_subtype(Bin),
            Base = #{type => Type, truncated => Truncated, total => Total, text => Bin},
            case Type of
                hll -> {ok, Base#{count => to_int(q_val(Pid, [<<"PFCOUNT">>, Key]), 0)}};
                bitmap -> {ok, Base#{bitcount => to_int(q_val(Pid, [<<"BITCOUNT">>, Key]), 0)}};
                _ -> {ok, Base}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec fetch_list(pid(), binary(), pos_integer()) -> {ok, map()} | {error, term()}.
fetch_list(Pid, Key, MaxItems) ->
    Total = to_int(q_val(Pid, [<<"LLEN">>, Key]), 0),
    Items = case eredis:q(Pid, [<<"LRANGE">>, Key, <<"0">>, integer_to_binary(MaxItems - 1)]) of
        {ok, L} -> L;
        _ -> []
    end,
    {ok, #{type => list, items => Items,
           truncated => Total > length(Items), total => Total}}.

-spec fetch_set(pid(), binary(), pos_integer()) -> {ok, map()} | {error, term()}.
fetch_set(Pid, Key, MaxItems) ->
    Total = to_int(q_val(Pid, [<<"SCARD">>, Key]), 0),
    Items = lists:sublist(scan_collect(Pid, [<<"SSCAN">>, Key], MaxItems), MaxItems),
    {ok, #{type => set, items => Items,
           truncated => Total > length(Items), total => Total}}.

-spec fetch_hash(pid(), binary(), pos_integer()) -> {ok, map()} | {error, term()}.
fetch_hash(Pid, Key, MaxItems) ->
    Total = to_int(q_val(Pid, [<<"HLEN">>, Key]), 0),
    Flat = lists:sublist(scan_collect(Pid, [<<"HSCAN">>, Key], MaxItems * 2), MaxItems * 2),
    Items = pair_up(Flat),
    {ok, #{type => hash, items => Items,
           truncated => Total > length(Items), total => Total}}.

-spec fetch_zset(pid(), binary(), pos_integer()) -> {ok, map()} | {error, term()}.
fetch_zset(Pid, Key, MaxItems) ->
    Total = to_int(q_val(Pid, [<<"ZCARD">>, Key]), 0),
    case eredis:q(Pid, [<<"ZRANGE">>, Key, <<"0">>,
                        integer_to_binary(MaxItems - 1), <<"WITHSCORES">>]) of
        {ok, Flat} ->
            Members = [{M, to_float(S)} || {M, S} <- pair_up(Flat)],
            Truncated = Total > length(Members),
            Scores = [S || {_, S} <- Members],
            case dui_redis_type:looks_like_geoscores(Scores) of
                true ->
                    case geopos(Pid, Key, [M || {M, _} <- Members]) of
                        [] ->
                            {ok, #{type => zset, items => Members,
                                   truncated => Truncated, total => Total}};
                        GeoMembers ->
                            {ok, #{type => geo, items => GeoMembers,
                                   truncated => Truncated, total => Total}}
                    end;
                false ->
                    {ok, #{type => zset, items => Members,
                           truncated => Truncated, total => Total}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec fetch_stream(pid(), binary(), pos_integer()) -> {ok, map()} | {error, term()}.
fetch_stream(Pid, Key, MaxItems) ->
    Total = to_int(q_val(Pid, [<<"XLEN">>, Key]), 0),
    case eredis:q(Pid, [<<"XRANGE">>, Key, <<"-">>, <<"+">>,
                        <<"COUNT">>, integer_to_binary(MaxItems)]) of
        {ok, Entries} ->
            Items = [{Id, pair_up(Fields)} || [Id, Fields] <- Entries],
            {ok, #{type => stream, items => Items,
                   truncated => Total > length(Items), total => Total}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec fetch_json(pid(), binary()) -> {ok, map()} | {error, term()}.
fetch_json(Pid, Key) ->
    case eredis:q(Pid, [<<"JSON.GET">>, Key, <<"$">>]) of
        {ok, Bin} -> {ok, #{type => json, text => Bin}};
        {error, Reason} -> {error, Reason}
    end.

-spec geopos(pid(), binary(), [binary()]) -> [{binary(), float(), float()}].
geopos(_Pid, _Key, []) ->
    [];
geopos(Pid, Key, Members) ->
    case eredis:q(Pid, [<<"GEOPOS">>, Key | Members]) of
        {ok, Positions} when is_list(Positions), length(Positions) =:= length(Members) ->
            lists:filtermap(
                fun({Member, Pos}) ->
                    case Pos of
                        [LonBin, LatBin] -> {true, {Member, to_float(LonBin), to_float(LatBin)}};
                        _ -> false
                    end
                end,
                lists:zip(Members, Positions));
        _ ->
            []
    end.

%% @doc Collects elements across SSCAN/HSCAN pages until `Max' or cursor 0.
-spec scan_collect(pid(), [binary()], pos_integer()) -> [binary()].
scan_collect(Pid, [Cmd, Key], Max) ->
    scan_collect(Pid, [Cmd, Key], <<"0">>, Max, []).

-spec scan_collect(pid(), [binary()], binary(), pos_integer(), [binary()]) -> [binary()].
scan_collect(_Pid, _Cmd, _Cursor, Max, Acc) when length(Acc) >= Max ->
    Acc;
scan_collect(Pid, [Cmd, Key], Cursor, Max, Acc) ->
    case eredis:q(Pid, [Cmd, Key, Cursor, <<"COUNT">>, integer_to_binary(Max)]) of
        {ok, [NextBin, Batch]} when is_list(Batch) ->
            Acc1 = Acc ++ Batch,
            case NextBin of
                <<"0">> -> Acc1;
                _ -> scan_collect(Pid, [Cmd, Key], NextBin, Max, Acc1)
            end;
        _ ->
            Acc
    end.

-spec do_db_size(pid()) -> {ok, non_neg_integer()} | {error, term()}.
do_db_size(Pid) ->
    case eredis:q(Pid, [<<"DBSIZE">>]) of
        {ok, NBin} -> {ok, to_int(NBin, 0)};
        {error, Reason} -> {error, Reason}
    end.

%% ---------------------------------------------------------------------------
%% Search
%% ---------------------------------------------------------------------------

-spec do_scan_regex(pid(), binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
do_scan_regex(Pid, Pattern, Max) ->
    case dui_redis_search:compile_regex(Pattern) of
        {ok, _MP} ->
            Keys = scan_all_keys(Pid, <<"*">>),
            Matching = [K || K <- Keys, dui_redis_search:regex_match(Pattern, K)],
            {ok, enrich(Pid, lists:sublist(Matching, Max))};
        {error, Reason} ->
            {error, {invalid_regex, Reason}}
    end.

-spec do_fuzzy_search(pid(), binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
do_fuzzy_search(Pid, Term, Max) ->
    Keys = scan_all_keys(Pid, <<"*">>),
    Maps = [#{key => K, type => string, ttl => -1} || K <- Keys],
    Ranked = dui_redis_search:fuzzy_rank(Maps, Term, Max),
    {ok, enrich(Pid, [maps:get(key, K) || K <- Ranked])}.

-spec do_search_by_value(pid(), binary(), binary(), pos_integer()) ->
    {ok, [map()]} | {error, term()}.
do_search_by_value(Pid, Pattern, Search, Max) ->
    Pattern1 = case Pattern of <<>> -> <<"*">>; _ -> Pattern end,
    Keys = scan_all_keys(Pid, Pattern1),
    Matches = search_value_keys(Pid, Keys, Search, Max, []),
    {ok, enrich(Pid, Matches)}.

-spec search_value_keys(pid(), [binary()], binary(), non_neg_integer(), [binary()]) ->
    [binary()].
search_value_keys(_Pid, [], _Search, _Max, Acc) ->
    lists:reverse(Acc);
search_value_keys(_Pid, _Keys, _Search, Max, Acc) when length(Acc) >= Max ->
    lists:reverse(Acc);
search_value_keys(Pid, [Key | Rest], Search, Max, Acc) ->
    Acc1 = case do_value_preview(Pid, Key) of
        {ok, Value} ->
            case dui_redis_search:value_contains(Search, Value) of
                true -> [Key | Acc];
                false -> Acc
            end;
        _ -> Acc
    end,
    search_value_keys(Pid, Rest, Search, Max, Acc1).

-spec do_compare_keys(pid(), binary(), binary()) ->
    {ok, {map(), map(), binary()}} | {error, term()}.
do_compare_keys(Pid, Key1, Key2) ->
    case {do_value_detail(Pid, Key1), do_value_detail(Pid, Key2)} of
        {{ok, V1}, {ok, V2}} ->
            {ok, {V1, V2, dui_redis_search:diff(V1, V2)}};
        {{error, Reason}, _} ->
            {error, Reason};
        {_, {error, Reason}} ->
            {error, Reason}
    end.

-spec scan_all_keys(pid(), binary()) -> [binary()].
scan_all_keys(Pid, Pattern) ->
    scan_all_keys(Pid, Pattern, <<"0">>, [], 0).

-spec scan_all_keys(pid(), binary(), binary(), [binary()], non_neg_integer()) -> [binary()].
scan_all_keys(_Pid, _Pattern, _Cursor, Acc, Count) when Count >= 100000 ->
    Acc;
scan_all_keys(Pid, Pattern, Cursor, Acc, Count) ->
    Cmd = [<<"SCAN">>, Cursor, <<"MATCH">>, Pattern, <<"COUNT">>, <<"1000">>],
    case eredis:q(Pid, Cmd) of
        {ok, [Next, Keys]} when is_list(Keys) ->
            Acc1 = Acc ++ Keys,
            case Next of
                <<"0">> -> Acc1;
                _ -> scan_all_keys(Pid, Pattern, Next, Acc1, Count + length(Keys))
            end;
        _ ->
            Acc
    end.

-spec enrich(pid(), [binary()]) -> [map()].
enrich(Pid, Keys) ->
    K0 = [#{key => K, type => string, ttl => -1} || K <- Keys],
    K1 = fill_type_ttl(Pid, K0),
    detect_string_subtypes(Pid, detect_zset_subtypes(Pid, K1)).

%% ---------------------------------------------------------------------------
%% Small helpers
%% ---------------------------------------------------------------------------

-spec q_val(pid(), [term()]) -> term().
q_val(Pid, Cmd) ->
    case eredis:q(Pid, Cmd) of
        {ok, V} -> V;
        _ -> undefined
    end.

-spec pair_up([term()]) -> [{term(), term()}].
pair_up([A, B | Rest]) -> [{A, B} | pair_up(Rest)];
pair_up(_) -> [].

-spec to_int(term(), integer()) -> integer().
to_int(Bin, _Default) when is_integer(Bin) -> Bin;
to_int(Bin, Default) when is_binary(Bin) ->
    try binary_to_integer(Bin)
    catch error:badarg -> Default
    end;
to_int(_Other, Default) -> Default.

-spec to_float(term()) -> float().
to_float(F) when is_float(F) -> F;
to_float(I) when is_integer(I) -> float(I);
to_float(Bin) when is_binary(Bin) ->
    try binary_to_float(Bin)
    catch error:badarg ->
        try binary_to_integer(Bin) * 1.0
        catch error:badarg -> 0.0
        end
    end;
to_float(_Other) -> 0.0.

-spec number_bin(number()) -> binary().
number_bin(I) when is_integer(I) -> integer_to_binary(I);
number_bin(F) -> iolist_to_binary(io_lib:format("~p", [F])).

-spec flat_fields([{term(), term()}]) -> [term()].
flat_fields(Fields) ->
    lists:flatmap(fun({K, V}) -> [to_bin(K), to_bin(V)] end, Fields).

-spec to_bin(term()) -> binary().
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
