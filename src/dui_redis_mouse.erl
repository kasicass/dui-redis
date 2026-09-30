%% @doc Invisible full-screen layer that turns mouse events into root messages.
%%
%% educkui dispatches mouse presses only to registered component targets; the
%% root component is not one, so this layer covers the whole screen (rendering
%% nothing) and bubbles `{mouse_click, X, Y}' / `{mouse_scroll, Dir, X, Y}' to
%% the root. Key and paste events are propagated so keyboard input still
%% reaches the root after this layer takes focus.
-module(dui_redis_mouse).

-behaviour(educkui_elm).

-include_lib("educkui/include/educkui.hrl").

-export([init/1, event_to_msg/2, update/2, view/1]).

-spec init([{atom(), term()}]) -> map().
init(_Opts) ->
    #{}.

-spec event_to_msg(#dui_event{}, map()) -> {msg, term()} | ignore | propagate.
event_to_msg(#dui_event{type = mouse, action = press, button = left, x = X, y = Y}, _State) ->
    {msg, {click, X, Y}};
event_to_msg(#dui_event{type = mouse, action = scroll_up, x = X, y = Y}, _State) ->
    {msg, {scroll, up, X, Y}};
event_to_msg(#dui_event{type = mouse, action = scroll_down, x = X, y = Y}, _State) ->
    {msg, {scroll, down, X, Y}};
event_to_msg(#dui_event{type = key}, _State) ->
    propagate;
event_to_msg(#dui_event{type = paste}, _State) ->
    propagate;
event_to_msg(_Event, _State) ->
    ignore.

-spec update(term(), map()) -> {map(), [educkui_command:command()]}.
update({click, X, Y}, State) ->
    {State, [educkui_command:parent({mouse_click, X, Y})]};
update({scroll, Dir, X, Y}, State) ->
    {State, [educkui_command:parent({mouse_scroll, Dir, X, Y})]};
update(_Msg, State) ->
    {State, []}.

-spec view(map()) -> #dui_node{}.
view(_State) ->
    educkui_render_node:empty().
