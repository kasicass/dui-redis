%% @doc Redis client wrapper around eredis.
%%
%% A single registered gen_server owns the active connection. All calls are
%% safe when the client is not running (they return `{error, no_client}'), so
%% application code never crashes on a missing process.
%%
%% M1 supports standalone connections; cluster mode is reported as
%% unsupported until M6.
-module(dui_redis_client).

-behaviour(gen_server).

-export([
    start_link/0,
    connect/1, disconnect/0, test/1, select_db/1,
    ping/0, q/1, q/2, is_connected/0, current/0,
    build_options/1, stop/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(CALL_TIMEOUT, 15000).

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Connects to the Redis instance described by `Conn'.
-spec connect(map()) -> ok | {error, term()}.
connect(Conn) ->
    call({connect, Conn}).

%% @doc Closes the active connection.
-spec disconnect() -> ok.
disconnect() ->
    call(disconnect).

%% @doc Opens a temporary connection, PINGs it, and closes it.
%% Returns the measured latency in milliseconds on success.
-spec test(map()) -> {ok, non_neg_integer()} | {error, term()}.
test(Conn) ->
    call({test, Conn}).

%% @doc Switches the active database (standalone only).
-spec select_db(integer()) -> ok | {error, term()}.
select_db(Db) ->
    call({select_db, Db}).

%% @doc PINGs the active connection.
-spec ping() -> {ok, term()} | {error, term()}.
ping() ->
    q([<<"PING">>]).

%% @doc Runs a command on the active connection.
-spec q([term()]) -> {ok, term()} | {error, term()}.
q(Command) ->
    call({q, Command}).

%% @doc Runs a command with a custom timeout.
-spec q([term()], timeout()) -> {ok, term()} | {error, term()}.
q(Command, Timeout) ->
    call({q, Command}, Timeout).

-spec is_connected() -> boolean().
is_connected() ->
    call(is_connected).

%% @doc Returns the currently connected config map, if any.
-spec current() -> {ok, map()} | undefined.
current() ->
    call(current).

-spec stop() -> ok.
stop() ->
    gen_server:stop(?SERVER).

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
%% Internal
%% ---------------------------------------------------------------------------

-spec call(term()) -> term().
call(Request) ->
    call(Request, ?CALL_TIMEOUT).

-spec call(term(), timeout()) -> term().
call(Request, Timeout) ->
    case whereis(?SERVER) of
        undefined -> {error, no_client};
        _ -> gen_server:call(?SERVER, Request, Timeout)
    end.

-spec do_connect(map(), map()) -> {reply, ok | {error, term()}, map()}.
do_connect(Conn, State) ->
    Options = build_options(Conn),
    case start_eredis(Options) of
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
                {ok, <<"PONG">>} ->
                    {ok, erlang:monotonic_time(millisecond) - Start};
                {ok, Other} ->
                    {error, {unexpected_reply, Other}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Starts an eredis client, converting exceptions into error tuples.
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
        {ok, <<"OK">>} ->
            ok;
        {ok, _Other} ->
            ok;
        {error, Reason} ->
            {error, Reason}
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
