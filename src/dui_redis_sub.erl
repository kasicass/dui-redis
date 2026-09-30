%% @doc Live Redis Pub/Sub subscription.
%%
%% Owns an `eredis_sub' connection and forwards every message to the educkui
%% root as a `{pubsub_message, Channel, Payload}' custom message (via
%% `educkui_runtime:send_message/3'), acknowledging each one. It is started
%% unlinked from the UI, so a connection failure cannot take down the runtime;
%% on exit it reports `{pubsub_stopped, Reason}'.
%%
%% A target containing `*', `?' or `[' is pattern-subscribed (PSUBSCRIBE),
%% anything else is a plain channel (SUBSCRIBE).
-module(dui_redis_sub).
-behaviour(gen_server).

-export([start/3, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-type kind() :: channel | pattern.
-type state() :: #{runtime := pid(), runtime_ref := reference(),
                   sub := pid() | undefined,
                   target := binary(), kind := kind()}.

%% @doc Starts a subscription to `Target' for `Conn', reporting to `Runtime'.
-spec start(pid(), map(), binary()) -> {ok, pid()} | {error, term()}.
start(Runtime, Conn, Target) ->
    gen_server:start(?MODULE, {Runtime, Conn, Target}, []).

%% @doc Stops the subscription.
-spec stop(pid()) -> ok.
stop(Pid) -> gen_server:cast(Pid, stop).

%% ---------------------------------------------------------------------------
%% gen_server
%% ---------------------------------------------------------------------------

-spec init({pid(), map(), binary()}) -> {ok, state()} | {stop, term()}.
init({Runtime, Conn, Target}) ->
    process_flag(trap_exit, true),
    %% Stop when the UI runtime exits so a quit doesn't leak the subscription.
    Ref = erlang:monitor(process, Runtime),
    Options = [{reconnect_sleep, 1000} | dui_redis_client:build_options(Conn)],
    case eredis_sub:start_link(Options) of
        {ok, Sub} ->
            ok = eredis_sub:controlling_process(Sub, self()),
            Kind = kind_of(Target),
            _ = do_subscribe(Sub, Kind, Target),
            {ok, #{runtime => Runtime, runtime_ref => Ref,
                   sub => Sub, target => Target, kind => Kind}};
        {error, Reason} ->
            {stop, Reason}
    end.

-spec handle_call(term(), {pid(), term()}, state()) -> {reply, ok, state()}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), state()) -> {noreply, state()} | {stop, normal, state()}.
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()} | {stop, term(), state()}.
handle_info({message, Channel, Payload, Sub}, #{sub := Sub} = State) ->
    forward(State, {pubsub_message, Channel, Payload}),
    eredis_sub:ack_message(Sub),
    {noreply, State};
handle_info({pmessage, _Pattern, Channel, Payload, Sub}, #{sub := Sub} = State) ->
    forward(State, {pubsub_message, Channel, Payload}),
    eredis_sub:ack_message(Sub),
    {noreply, State};
handle_info({subscribed, Channel, Sub}, #{sub := Sub} = State) ->
    forward(State, {pubsub_subscribed, Channel}),
    %% eredis_sub queues every subsequent message until the previous one is
    %% acked, including this subscription acknowledgement.
    eredis_sub:ack_message(Sub),
    {noreply, State};
handle_info({unsubscribed, Channel, Sub}, #{sub := Sub} = State) ->
    forward(State, {pubsub_unsubscribed, Channel}),
    eredis_sub:ack_message(Sub),
    {noreply, State};
handle_info({eredis_disconnected, Sub}, #{sub := Sub} = State) ->
    forward(State, pubsub_disconnected),
    eredis_sub:ack_message(Sub),
    {noreply, State};
handle_info({eredis_connected, Sub}, #{sub := Sub} = State) ->
    forward(State, pubsub_connected),
    eredis_sub:ack_message(Sub),
    {noreply, State};
handle_info({'DOWN', Ref, process, _Pid, Reason}, #{runtime_ref := Ref} = State) ->
    {stop, Reason, State};
handle_info({'EXIT', Sub, Reason}, #{sub := Sub} = State) ->
    {stop, Reason, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(Reason, #{sub := Sub} = State) when is_pid(Sub) ->
    forward(State, {pubsub_stopped, Reason}),
    catch eredis_sub:stop(Sub),
    ok;
terminate(Reason, State) ->
    forward(State, {pubsub_stopped, Reason}),
    ok.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

-spec kind_of(binary()) -> kind().
kind_of(Target) ->
    case binary:match(Target, [<<"*">>, <<"?">>, <<"[">>]) of
        nomatch -> channel;
        _ -> pattern
    end.

-spec do_subscribe(pid(), kind(), binary()) -> ok.
do_subscribe(Sub, channel, Target) -> eredis_sub:subscribe(Sub, [Target]);
do_subscribe(Sub, pattern, Target) -> eredis_sub:psubscribe(Sub, [Target]).

-spec forward(state(), term()) -> ok.
forward(#{runtime := Runtime}, Msg) when is_pid(Runtime) ->
    case is_process_alive(Runtime) of
        true -> educkui_runtime:send_message(Runtime, root, Msg);
        false -> ok
    end;
forward(_State, _Msg) ->
    ok.
