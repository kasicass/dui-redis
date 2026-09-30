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
    set_connections/2,
    upsert_connection/2,
    remove_connection/2,
    selected/1,
    set_selected/2,
    current_conn/1,
    set_current_conn/2,
    editing_conn/1,
    set_editing_conn/2,
    conn_form/1,
    set_conn_form/2,
    confirm/1,
    set_confirm/2,
    clear_confirm/1,
    test_result/1,
    set_test_result/2,
    connection_error/1,
    set_connection_error/2,
    connected/1,
    set_connected/2,
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
        config_path = to_path(maps:get(config_path, CliOpts, undefined)),
        loading = true
    }.

-spec to_path(term()) -> string() | undefined.
to_path(undefined) -> undefined;
to_path(Path) when is_binary(Path) -> binary_to_list(Path);
to_path(Path) when is_list(Path) -> Path.

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

-spec set_connections(#dui_state{}, [map()]) -> #dui_state{}.
set_connections(State, Conns) when is_list(Conns) ->
    State#dui_state{connections = Conns, loading = false}.

-spec upsert_connection(#dui_state{}, map()) -> #dui_state{}.
upsert_connection(#dui_state{connections = Conns} = State, Conn) ->
    Id = maps:get(id, Conn, undefined),
    case lists:any(fun(C) -> maps:get(id, C, undefined) =:= Id end, Conns) of
        true ->
            State#dui_state{connections = [case maps:get(id, C, undefined) =:= Id of
                                              true -> Conn;
                                              false -> C
                                          end || C <- Conns]};
        false ->
            State#dui_state{connections = Conns ++ [Conn]}
    end.

-spec remove_connection(#dui_state{}, integer()) -> #dui_state{}.
remove_connection(#dui_state{connections = Conns} = State, Id) ->
    State#dui_state{connections = [C || C <- Conns, maps:get(id, C, undefined) =/= Id]}.

-spec selected(#dui_state{}) -> non_neg_integer().
selected(#dui_state{selected = Selected}) -> Selected.

-spec set_selected(#dui_state{}, non_neg_integer()) -> #dui_state{}.
set_selected(State, Selected) ->
    State#dui_state{selected = max(0, Selected)}.

-spec current_conn(#dui_state{}) -> map() | undefined.
current_conn(#dui_state{current_conn = Conn}) -> Conn.

-spec set_current_conn(#dui_state{}, map() | undefined) -> #dui_state{}.
set_current_conn(State, Conn) ->
    State#dui_state{current_conn = Conn}.

-spec editing_conn(#dui_state{}) -> map() | undefined.
editing_conn(#dui_state{editing_conn = Conn}) -> Conn.

-spec set_editing_conn(#dui_state{}, map() | undefined) -> #dui_state{}.
set_editing_conn(State, Conn) ->
    State#dui_state{editing_conn = Conn}.

-spec conn_form(#dui_state{}) -> map().
conn_form(#dui_state{conn_form = Form}) -> Form.

-spec set_conn_form(#dui_state{}, map()) -> #dui_state{}.
set_conn_form(State, Form) ->
    State#dui_state{conn_form = Form}.

-spec confirm(#dui_state{}) -> term() | undefined.
confirm(#dui_state{confirm = Confirm}) -> Confirm.

-spec set_confirm(#dui_state{}, term()) -> #dui_state{}.
set_confirm(State, Confirm) ->
    State#dui_state{confirm = Confirm}.

-spec clear_confirm(#dui_state{}) -> #dui_state{}.
clear_confirm(State) ->
    State#dui_state{confirm = undefined}.

-spec test_result(#dui_state{}) -> binary() | undefined.
test_result(#dui_state{test_result = Result}) -> Result.

-spec set_test_result(#dui_state{}, binary() | undefined) -> #dui_state{}.
set_test_result(State, Result) ->
    State#dui_state{test_result = Result}.

-spec connection_error(#dui_state{}) -> binary() | undefined.
connection_error(#dui_state{connection_error = Error}) -> Error.

-spec set_connection_error(#dui_state{}, binary() | undefined) -> #dui_state{}.
set_connection_error(State, Error) ->
    State#dui_state{connection_error = Error}.

-spec connected(#dui_state{}) -> boolean().
connected(#dui_state{connected = Connected}) -> Connected.

-spec set_connected(#dui_state{}, boolean()) -> #dui_state{}.
set_connected(State, Connected) when is_boolean(Connected) ->
    State#dui_state{connected = Connected}.

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
