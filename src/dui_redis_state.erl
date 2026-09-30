%% @doc Root state constructors and pure state transitions.
-module(dui_redis_state).

-include("dui_redis.hrl").

-export([
    new/2,
    screen/1,
    size/1,
    width/1,
    height/1,
    connections/1,
    status/1,
    show_help/1,
    config_path/1,
    cli/1,
    ticks/1,
    loading/1,
    put_config/2,
    set_status/3,
    clear_status/1,
    toggle_help/1,
    close_help/1,
    set_screen/2,
    set_size/3,
    incr_tick/1,
    set_loading/2
]).

-spec new(pid(), map()) -> #dui_state{}.
new(Runtime, CliOpts) ->
    #dui_state{
        runtime = Runtime,
        cli = CliOpts,
        config_path = maps:get(config_path, CliOpts, undefined),
        loading = true
    }.

-spec screen(#dui_state{}) -> atom().
screen(#dui_state{screen = Screen}) -> Screen.

-spec size(#dui_state{}) -> {pos_integer(), pos_integer()}.
size(#dui_state{size = Size}) -> Size.

-spec width(#dui_state{}) -> pos_integer().
width(#dui_state{size = {_H, W}}) -> W.

-spec height(#dui_state{}) -> pos_integer().
height(#dui_state{size = {H, _W}}) -> H.

-spec connections(#dui_state{}) -> [map()].
connections(#dui_state{connections = Conns}) -> Conns.

-spec status(#dui_state{}) -> {info | error, binary()} | undefined.
status(#dui_state{status = Status}) -> Status.

-spec show_help(#dui_state{}) -> boolean().
show_help(#dui_state{show_help = Show}) -> Show.

-spec config_path(#dui_state{}) -> string() | undefined.
config_path(#dui_state{config_path = Path}) -> Path.

-spec cli(#dui_state{}) -> map().
cli(#dui_state{cli = Cli}) -> Cli.

-spec ticks(#dui_state{}) -> non_neg_integer().
ticks(#dui_state{ticks = Ticks}) -> Ticks.

-spec loading(#dui_state{}) -> boolean().
loading(#dui_state{loading = Loading}) -> Loading.

-spec put_config(#dui_state{}, map()) -> #dui_state{}.
put_config(State, Config) ->
    State#dui_state{
        connections = maps:get(connections, Config, []),
        loading = false
    }.

-spec set_status(#dui_state{}, info | error, binary() | string()) -> #dui_state{}.
set_status(State, Level, Msg) ->
    State#dui_state{status = {Level, to_binary(Msg)}}.

-spec clear_status(#dui_state{}) -> #dui_state{}.
clear_status(State) ->
    State#dui_state{status = undefined}.

-spec toggle_help(#dui_state{}) -> #dui_state{}.
toggle_help(#dui_state{show_help = true} = State) ->
    State#dui_state{show_help = false};
toggle_help(#dui_state{screen = Screen} = State) ->
    State#dui_state{screen = Screen, prev_screen = Screen, show_help = true}.

-spec close_help(#dui_state{}) -> #dui_state{}.
close_help(#dui_state{show_help = true} = State) ->
    State#dui_state{show_help = false};
close_help(State) ->
    State.

-spec set_screen(#dui_state{}, atom()) -> #dui_state{}.
set_screen(State, Screen) ->
    State#dui_state{screen = Screen, show_help = false, status = undefined}.

-spec set_size(#dui_state{}, pos_integer(), pos_integer()) -> #dui_state{}.
set_size(State, Rows, Cols) ->
    State#dui_state{size = {Rows, Cols}}.

-spec incr_tick(#dui_state{}) -> #dui_state{}.
incr_tick(#dui_state{ticks = Ticks} = State) ->
    State#dui_state{ticks = Ticks + 1}.

-spec set_loading(#dui_state{}, boolean()) -> #dui_state{}.
set_loading(State, Loading) ->
    State#dui_state{loading = Loading}.

-spec to_binary(binary() | string()) -> binary().
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L).
