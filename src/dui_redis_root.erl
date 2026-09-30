%% -*- coding: utf-8 -*-
%% @doc Root educkui component.
%%
%% Owns all application state (mirroring redis-tui's `Model') and dispatches
%% rendering to per-screen view functions. M0 implements the skeleton:
%% connections screen, help overlay and status bar, plus proof-of-life for the
%% educkui runtime features (async command results, intervals, resize).
-module(dui_redis_root).

-behaviour(educkui_elm).

-include_lib("educkui/include/educkui.hrl").
-include("dui_redis.hrl").

-export([init/1, event_to_msg/2, update/2, view/1]).

%% ---------------------------------------------------------------------------
%% init
%% ---------------------------------------------------------------------------

-spec init([{atom(), term()}]) -> {#dui_state{}, [educkui_command:command()]}.
init(Opts) ->
    Runtime = self(),
    CliOpts = proplists:get_value(opts, Opts, #{}),
    State0 = dui_redis_state:new(Runtime, CliOpts),
    Commands = [
        dui_redis_cmd:load_config(State0),
        educkui_command:interval(tick, 1000)
    ],
    {State0, Commands}.

%% ---------------------------------------------------------------------------
%% event_to_msg
%% ---------------------------------------------------------------------------

-spec event_to_msg(#dui_event{}, #dui_state{}) ->
    {msg, term()} | ignore | propagate.
event_to_msg(#dui_event{type = key, key = Key, modifiers = Mods}, _State) ->
    {msg, {key, Key, Mods}};
event_to_msg(#dui_event{type = custom, key = parent, content = Msg}, _State) ->
    {msg, Msg};
event_to_msg(#dui_event{type = custom, key = command_result,
                        content = {_ComponentId, Msg}}, _State) ->
    {msg, Msg};
event_to_msg(#dui_event{type = resize, width = W, height = H}, _State) ->
    {msg, {resize, W, H}};
event_to_msg(_Event, _State) ->
    ignore.

%% ---------------------------------------------------------------------------
%% update
%% ---------------------------------------------------------------------------

-spec update(term(), #dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
update(quit, State) ->
    {State, [educkui_command:quit()]};
update(toggle_help, State) ->
    {dui_redis_state:toggle_help(State), []};
update(close_help, State) ->
    {dui_redis_state:close_help(State), []};
update(tick, State) ->
    {dui_redis_state:incr_tick(State), []};
update({resize, W, H}, State) ->
    {dui_redis_state:set_size(State, H, W), []};
update({config_loaded, {ok, Config}}, State) ->
    {dui_redis_state:put_config(State, Config), []};
update({config_loaded, {error, Reason}}, State) ->
    Msg = iolist_to_binary(io_lib:format("config: ~p", [Reason])),
    {dui_redis_state:set_status(State, error, Msg), []};
update({key, Key, Mods}, State) ->
    handle_key(Key, Mods, State);
update(_Msg, State) ->
    {State, []}.

%% ---------------------------------------------------------------------------
%% Key handling
%% ---------------------------------------------------------------------------

-spec handle_key(term(), [atom()], #dui_state{}) ->
    {#dui_state{}, [educkui_command:command()]}.
handle_key(<<"c">>, Mods, State) ->
    case lists:member(ctrl, Mods) of
        true -> {State, [educkui_command:quit()]};
        false -> {State, []}
    end;
handle_key(<<"q">>, _Mods, State) ->
    {State, [educkui_command:quit()]};
handle_key(<<"?">>, _Mods, State) ->
    {dui_redis_state:toggle_help(State), []};
handle_key(esc, _Mods, State) ->
    {dui_redis_state:close_help(State), []};
handle_key(_Key, _Mods, State) ->
    {State, []}.

%% ---------------------------------------------------------------------------
%% view
%% ---------------------------------------------------------------------------

-spec view(#dui_state{}) -> #dui_node{}.
view(State) ->
    educkui_render_node:stack(vertical, [
        title_bar(State),
        body(State),
        status_bar(State)
    ]).

-spec title_bar(#dui_state{}) -> #dui_node{}.
title_bar(State) ->
    Version = list_to_binary(?DUI_REDIS_VERSION),
    Screen = dui_redis_fmt:screen_name(dui_redis_state:screen(State)),
    Text = <<" dui-redis ", Version/binary, "  |  ", Screen/binary>>,
    educkui_render_node:height(
        educkui_render_node:text(Text, dui_redis_theme:title()), 1).

-spec body(#dui_state{}) -> #dui_node{}.
body(State) ->
    case dui_redis_state:show_help(State) of
        true -> help_view();
        false -> screen_view(State)
    end.

-spec screen_view(#dui_state{}) -> #dui_node{}.
screen_view(State) ->
    case dui_redis_state:screen(State) of
        connections -> connections_view(State);
        _ -> educkui_render_node:empty()
    end.

-spec connections_view(#dui_state{}) -> #dui_node{}.
connections_view(State) ->
    Connections = dui_redis_state:connections(State),
    Items = case Connections of
        [] -> [<<"(no saved connections - connection management arrives in M1)">>];
        _ -> [dui_redis_fmt:connection_label(C) || C <- Connections]
    end,
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<" Connections">>, dui_redis_theme:subtitle()),
        educkui_render_node:widget(educkui_widget_list, #{
            items => Items,
            selected => 0,
            style => educkui_style:new(),
            selected_style => dui_redis_theme:selected()
        })
    ]).

-spec help_view() -> #dui_node{}.
help_view() ->
    Lines = [
        <<"">>,
        <<"  Global shortcuts">>,
        <<"">>,
        <<"    ?        toggle this help">>,
        <<"    q        quit">>,
        <<"    Ctrl+C   quit">>,
        <<"    Esc      close help">>,
        <<"">>,
        <<"  M0 skeleton - key management arrives in later milestones.">>
    ],
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<" Help">>, dui_redis_theme:title())
        | [educkui_render_node:text(Line) || Line <- Lines]
    ]).

-spec status_bar(#dui_state{}) -> #dui_node{}.
status_bar(State) ->
    {Text, Style} = case dui_redis_state:status(State) of
        undefined -> {hint(State), dui_redis_theme:dim()};
        {info, Msg} -> {Msg, dui_redis_theme:info()};
        {error, Msg} -> {Msg, dui_redis_theme:error()}
    end,
    educkui_render_node:height(educkui_render_node:text(Text, Style), 1).

-spec hint(#dui_state{}) -> binary().
hint(State) ->
    {Rows, Cols} = dui_redis_state:size(State),
    Ticks = dui_redis_state:ticks(State),
    iolist_to_binary(io_lib:format(
        " ? help   q quit        ~bx~b   tick ~b", [Cols, Rows, Ticks])).
