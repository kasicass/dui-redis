%% -*- coding: utf-8 -*-
%% @doc Root educkui component.
%%
%% Owns all application state (mirroring redis-tui's `Model') and dispatches
%% rendering to per-screen view functions. M1 implements connection management:
%% list, add/edit form, test connection, delete confirmation and connect.
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
update(tick, State) ->
    {dui_redis_state:incr_tick(State), []};
update({resize, W, H}, State) ->
    {dui_redis_state:set_size(State, H, W), []};
update({config_loaded, {ok, Config}}, State) ->
    maybe_auto_connect(dui_redis_state:put_config(State, Config));
update({config_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({connections_loaded, {ok, Conns}}, State) ->
    {dui_redis_state:set_connections(State, Conns), []};
update({connections_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({connection_added, {ok, Conn}}, State) ->
    finish_form(State, Conn, <<"Connection added">>);
update({connection_added, {error, Reason}}, State) ->
    form_error(State, Reason);
update({connection_updated, {ok, Conn}}, State) ->
    finish_form(State, Conn, <<"Connection updated">>);
update({connection_updated, {error, Reason}}, State) ->
    form_error(State, Reason);
update({connection_deleted, Id, ok}, State) ->
    S1 = dui_redis_state:remove_connection(State, Id),
    S2 = dui_redis_state:set_screen(S1, connections),
    {dui_redis_state:set_status(S2, info, <<"Connection deleted">>), []};
update({connection_deleted, _Id, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({connection_tested, Result}, State) ->
    update_test_result(State, Result);
update({connected, ok}, State) ->
    S1 = dui_redis_state:set_screen(State, keys),
    S2 = dui_redis_state:set_connected(S1, true),
    S3 = dui_redis_state:set_connection_error(S2, undefined),
    S4 = dui_redis_state:set_loading(S3, false),
    S5 = dui_redis_state:set_status(S4, info, <<"Connected">>),
    reload_keys(S5);
update({connected, {error, Reason}}, State) ->
    S1 = dui_redis_state:set_loading(State, false),
    S2 = dui_redis_state:set_connection_error(S1, error_text(Reason)),
    {dui_redis_state:set_status(S2, error, <<"Connection failed">>), []};
update({disconnected, _}, State) ->
    S1 = dui_redis_state:set_screen(State, connections),
    S2 = dui_redis_state:set_connected(S1, false),
    S3 = dui_redis_state:set_current_conn(S2, undefined),
    {dui_redis_state:set_status(S3, info, <<"Disconnected">>), []};
update({keys_loaded, Cursor, {ok, Result}}, State) ->
    Keys = maps:get(keys, Result, []),
    Next = maps:get(cursor, Result, 0),
    Total = maps:get(total, Result, 0),
    S1 = dui_redis_state:set_keys(State, Keys, Cursor),
    S2 = dui_redis_state:set_key_cursor(S1, Next),
    S3 = dui_redis_state:set_total_keys(S2, Total),
    S4 = sort_state_keys(clamp_selected(S3)),
    load_selected_preview(S4);
update({keys_loaded, _Cursor, {error, Reason}}, State) ->
    S1 = dui_redis_state:set_loading_keys(State, false),
    {dui_redis_state:set_status(S1, error, error_text(Reason)), []};
update({preview_loaded, Key, {ok, Value}}, State) ->
    case dui_redis_state:preview_key(State) =:= Key of
        true -> {dui_redis_state:set_preview(State, Key, Value), []};
        false -> {State, []}
    end;
update({preview_loaded, _Key, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({db_switched, _Db, {error, Reason}}, State) ->
    S1 = dui_redis_state:set_screen(State, keys),
    {dui_redis_state:set_status(S1, error, error_text(Reason)), []};
update({db_switched, Db, ok}, State) ->
    Msg = <<"Switched to db", (integer_to_binary(Db))/binary>>,
    S1 = dui_redis_state:set_screen(State, keys),
    S2 = dui_redis_state:set_status(S1, info, Msg),
    reload_keys(S2);
update({filter_debounced, Seq, Pattern}, State) ->
    case dui_redis_state:search_seq(State) =:= Seq of
        true ->
            S1 = dui_redis_state:set_key_pattern(State, Pattern),
            reload_keys(S1);
        false ->
            {State, []}
    end;
update({detail_loaded, Key, {ok, Value}}, State) ->
    S1 = dui_redis_state:set_current_key(State, find_key_map(State, Key)),
    S2 = dui_redis_state:set_current_value(S1, Value),
    S3 = dui_redis_state:set_detail_scroll(S2, 0),
    {dui_redis_state:set_screen(S3, key_detail), []};
update({detail_loaded, _Key, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({value_saved, {ok, _}}, State) ->
    S1 = dui_redis_state:set_screen(State, key_detail),
    S2 = dui_redis_state:set_status(S1, info, <<"Value saved">>),
    refresh_detail(S2);
update({value_saved, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({key_deleted, _Key, {ok, _}}, State) ->
    S1 = dui_redis_state:set_screen(State, keys),
    S2 = dui_redis_state:set_status(S1, info, <<"Key deleted">>),
    reload_keys(S2);
update({key_deleted, _Key, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({key_renamed, {ok, _}}, State) ->
    S1 = dui_redis_state:set_screen(State, keys),
    S2 = dui_redis_state:set_status(S1, info, <<"Key renamed">>),
    reload_keys(S2);
update({key_renamed, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({key_copied, {ok, _}}, State) ->
    S1 = dui_redis_state:set_screen(State, keys),
    S2 = dui_redis_state:set_status(S1, info, <<"Key copied">>),
    reload_keys(S2);
update({key_copied, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({ttl_set, {ok, _}}, State) ->
    S1 = dui_redis_state:set_screen(State, key_detail),
    S2 = dui_redis_state:set_status(S1, info, <<"TTL updated">>),
    refresh_detail(S2);
update({ttl_set, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({db_flushed, {ok, _}}, State) ->
    S1 = dui_redis_state:set_status(State, info, <<"Database flushed">>),
    reload_keys(S1);
update({db_flushed, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({collection_added, {ok, _}}, State) ->
    S1 = dui_redis_state:set_status(State, info, <<"Item added">>),
    refresh_detail(S1);
update({collection_added, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({collection_removed, {ok, _}}, State) ->
    S1 = dui_redis_state:set_status(State, info, <<"Item removed">>),
    refresh_detail(S1);
update({collection_removed, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({favorites_loaded, {ok, Favs}}, State) ->
    S1 = dui_redis_state:set_results(State, Favs, {<<"Favorites">>, favorites}),
    {dui_redis_state:set_screen(S1, results), []};
update({favorites_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({favorite_added, _Key, {ok, _}}, State) ->
    {dui_redis_state:set_status(State, info, <<"Added to favorites">>), []};
update({favorite_added, _Key, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({favorite_removed, _Key, ok}, State) ->
    case dui_redis_state:results_purpose(State) of
        favorites -> start_favorites(State);
        _ -> {State, []}
    end;
update({favorite_removed, _Key, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({recent_loaded, {ok, Recent}}, State) ->
    S1 = dui_redis_state:set_results(State, Recent, {<<"Recent Keys">>, recent}),
    {dui_redis_state:set_screen(S1, results), []};
update({recent_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({recent_added, _Result}, State) ->
    {State, []};
update({recent_cleared, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({recent_cleared, _}, State) ->
    S1 = dui_redis_state:set_results(State, [], {<<"Recent Keys">>, recent}),
    {dui_redis_state:set_status(S1, info, <<"Recent keys cleared">>), []};
update({templates_loaded, {ok, Templates}}, State) ->
    S1 = dui_redis_state:set_results(State, Templates, {<<"Templates">>, templates}),
    {dui_redis_state:set_screen(S1, results), []};
update({templates_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({search_results, {Title, Purpose}, {ok, Keys}}, State) ->
    S1 = dui_redis_state:set_results(State, Keys, {Title, Purpose}),
    {dui_redis_state:set_screen(S1, results), []};
update({search_results, _Info, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({compare_result, {ok, {V1, V2, Diff}}}, State) ->
    Text = build_compare_text(V1, V2, Diff),
    S1 = dui_redis_state:set_result_text(State, Text),
    {dui_redis_state:set_screen(S1, result_text), []};
update({compare_result, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({json_result, {ok, Value}}, State) ->
    S1 = dui_redis_state:set_result_text(State, to_bin(Value)),
    {dui_redis_state:set_screen(S1, result_text), []};
update({json_result, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({key, Key, Mods}, State) ->
    handle_event(Key, Mods, State);
update(_Msg, State) ->
    {State, []}.

%% ---------------------------------------------------------------------------
%% Key handling
%% ---------------------------------------------------------------------------

-spec handle_event(term(), [atom()], #dui_state{}) ->
    {#dui_state{}, [educkui_command:command()]}.
handle_event(Key, Mods, State) ->
    case dui_redis_state:show_help(State) of
        true -> handle_help_key(Key, Mods, State);
        false -> handle_key(Key, Mods, State)
    end.

-spec handle_help_key(term(), [atom()], #dui_state{}) ->
    {#dui_state{}, [educkui_command:command()]}.
handle_help_key(<<"?">>, _Mods, State) ->
    {dui_redis_state:close_help(State), []};
handle_help_key(esc, _Mods, State) ->
    {dui_redis_state:close_help(State), []};
handle_help_key(Key, Mods, State) ->
    handle_global(Key, Mods, State).

-spec handle_key(term(), [atom()], #dui_state{}) ->
    {#dui_state{}, [educkui_command:command()]}.
handle_key(esc, _Mods, State) ->
    handle_escape(State);
handle_key(Key, Mods, State) ->
    handle_global(Key, Mods, State).

-spec handle_global(term(), [atom()], #dui_state{}) ->
    {#dui_state{}, [educkui_command:command()]}.
handle_global(<<"c">>, Mods, State) ->
    case lists:member(ctrl, Mods) of
        true -> {State, [educkui_command:quit()]};
        false -> screen_key(State, <<"c">>, Mods)
    end;
handle_global(<<"q">>, Mods, State) ->
    case text_entry_active(State) of
        true -> screen_key(State, <<"q">>, Mods);
        false -> {State, [educkui_command:quit()]}
    end;
handle_global(<<"?">>, Mods, State) ->
    case text_entry_active(State) of
        true -> screen_key(State, <<"?">>, Mods);
        false -> {dui_redis_state:toggle_help(State), []}
    end;
handle_global(Key, Mods, State) ->
    screen_key(State, Key, Mods).

-spec text_entry_active(#dui_state{}) -> boolean().
text_entry_active(#dui_state{screen = connection_form}) -> true;
text_entry_active(#dui_state{screen = switch_db}) -> true;
text_entry_active(#dui_state{screen = edit_value}) -> true;
text_entry_active(#dui_state{screen = prompt}) -> true;
text_entry_active(#dui_state{filter_active = true}) -> true;
text_entry_active(_State) -> false.

-spec handle_escape(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
handle_escape(#dui_state{filter_active = true} = State) ->
    S1 = dui_redis_state:set_filter_active(State, false),
    {dui_redis_state:set_filter_edit(S1, undefined), []};
handle_escape(#dui_state{screen = key_detail} = State) ->
    {dui_redis_state:set_screen(State, keys), []};
handle_escape(#dui_state{screen = results} = State) ->
    {dui_redis_state:set_screen(State, keys), []};
handle_escape(#dui_state{screen = tree} = State) ->
    {dui_redis_state:set_screen(State, keys), []};
handle_escape(#dui_state{screen = result_text} = State) ->
    {dui_redis_state:set_screen(State, keys), []};
handle_escape(#dui_state{screen = edit_value} = State) ->
    {dui_redis_state:set_screen(State, key_detail), []};
handle_escape(#dui_state{screen = prompt} = State) ->
    S1 = dui_redis_state:set_prompt(State, undefined),
    {dui_redis_state:set_screen(S1, key_detail), []};
handle_escape(#dui_state{screen = connection_form} = State) ->
    cancel_form(State);
handle_escape(#dui_state{screen = test_connection} = State) ->
    {dui_redis_state:set_screen(State, connection_form), []};
handle_escape(#dui_state{screen = confirm_delete} = State) ->
    S1 = dui_redis_state:clear_confirm(State),
    {dui_redis_state:set_screen(S1, connections), []};
handle_escape(#dui_state{screen = keys} = State) ->
    {dui_redis_state:set_loading(State, true), [dui_redis_cmd:disconnect()]};
handle_escape(#dui_state{screen = switch_db} = State) ->
    {dui_redis_state:set_screen(State, keys), []};
handle_escape(State) ->
    {dui_redis_state:clear_status(State), []}.

-spec screen_key(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
screen_key(#dui_state{screen = connections} = State, Key, Mods) ->
    connections_key(State, Key, Mods);
screen_key(#dui_state{screen = connection_form} = State, Key, Mods) ->
    form_key(State, Key, Mods);
screen_key(#dui_state{screen = test_connection} = State, Key, _Mods) ->
    test_key(State, Key);
screen_key(#dui_state{screen = confirm_delete} = State, Key, _Mods) ->
    confirm_key(State, Key);
screen_key(#dui_state{screen = keys} = State, Key, Mods) ->
    keys_screen_key(State, Key, Mods);
screen_key(#dui_state{screen = key_detail} = State, Key, Mods) ->
    detail_key(State, Key, Mods);
screen_key(#dui_state{screen = edit_value} = State, Key, Mods) ->
    editor_key(State, Key, Mods);
screen_key(#dui_state{screen = prompt} = State, Key, Mods) ->
    prompt_key(State, Key, Mods);
screen_key(#dui_state{screen = results} = State, Key, Mods) ->
    results_key(State, Key, Mods);
screen_key(#dui_state{screen = tree} = State, Key, Mods) ->
    tree_key(State, Key, Mods);
screen_key(#dui_state{screen = result_text} = State, _Key, _Mods) ->
    {State, []};
screen_key(#dui_state{screen = switch_db} = State, Key, _Mods) ->
    switch_db_key(State, Key);
screen_key(State, _Key, _Mods) ->
    {State, []}.

%% -- connections ------------------------------------------------------------

-spec connections_key(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
connections_key(State, Key, _Mods) when Key =:= <<"j">>; Key =:= down ->
    {move_selected(State, 1), []};
connections_key(State, Key, _Mods) when Key =:= <<"k">>; Key =:= up ->
    {move_selected(State, -1), []};
connections_key(State, enter, _Mods) ->
    connect_selected(State);
connections_key(State, Key, _Mods) when Key =:= <<"a">>; Key =:= <<"n">> ->
    open_add_form(State);
connections_key(State, <<"e">>, _Mods) ->
    open_edit_form(State);
connections_key(State, Key, _Mods)
        when Key =:= <<"d">>; Key =:= delete; Key =:= backspace ->
    open_confirm_delete(State);
connections_key(State, <<"r">>, _Mods) ->
    S1 = dui_redis_state:set_loading(State, true),
    {S1, [dui_redis_cmd:load_connections(State)]};
connections_key(State, _Key, _Mods) ->
    {State, []}.

%% -- connection form --------------------------------------------------------

-spec form_key(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
form_key(State, tab, Mods) ->
    Form = dui_redis_state:conn_form(State),
    Form1 = case lists:member(shift, Mods) of
        true -> dui_redis_form:focus_prev(Form);
        false -> dui_redis_form:focus_next(Form)
    end,
    {set_form(State, Form1), []};
form_key(State, down, _Mods) ->
    form_focus_next(State);
form_key(State, up, _Mods) ->
    form_focus_prev(State);
form_key(State, enter, _Mods) ->
    form_submit_or_toggle(State);
form_key(State, <<" ">>, _Mods) ->
    form_space_or_toggle(State);
form_key(State, <<"t">>, Mods) ->
    case lists:member(ctrl, Mods) of
        true -> form_test(State);
        false -> form_edit(State, <<"t">>, Mods)
    end;
form_key(State, Key, Mods) ->
    form_edit(State, Key, Mods).

-spec form_edit(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
form_edit(State, Key, Mods) ->
    Form = dui_redis_state:conn_form(State),
    Form1 = case Key of
        backspace -> dui_redis_form:backspace(Form);
        delete -> dui_redis_form:delete(Form);
        left -> dui_redis_form:move(left, Form);
        right -> dui_redis_form:move(right, Form);
        home -> dui_redis_form:home(Form);
        'end' -> dui_redis_form:'end'(Form);
        _ when is_binary(Key) ->
            case has_ctrl_like(Mods) of
                true -> Form;
                false -> dui_redis_form:insert(Key, Form)
            end;
        _ ->
            Form
    end,
    {set_form(State, Form1), []}.

-spec form_focus_next(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
form_focus_next(State) ->
    {set_form(State, dui_redis_form:focus_next(dui_redis_state:conn_form(State))), []}.

-spec form_focus_prev(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
form_focus_prev(State) ->
    {set_form(State, dui_redis_form:focus_prev(dui_redis_state:conn_form(State))), []}.

-spec form_space_or_toggle(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
form_space_or_toggle(State) ->
    Form = dui_redis_state:conn_form(State),
    case field_type(Form) of
        bool -> {set_form(State, dui_redis_form:toggle(Form)), []};
        _ -> {set_form(State, dui_redis_form:insert(<<" ">>, Form)), []}
    end.

-spec form_submit_or_toggle(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
form_submit_or_toggle(State) ->
    Form = dui_redis_state:conn_form(State),
    case field_type(Form) of
        bool ->
            {set_form(State, dui_redis_form:toggle(Form)), []};
        _ ->
            submit_form(State, Form)
    end.

-spec submit_form(#dui_state{}, map()) -> {#dui_state{}, [educkui_command:command()]}.
submit_form(State, Form) ->
    case dui_redis_form:validate(Form) of
        ok ->
            Conn = dui_redis_form:to_connection(Form),
            Cmd = case dui_redis_form:mode(Form) of
                add -> dui_redis_cmd:add_connection(State, Conn);
                edit -> dui_redis_cmd:update_connection(State, Conn)
            end,
            {dui_redis_state:set_loading(State, true), [Cmd]};
        {error, Msg} ->
            {set_form(State, dui_redis_form:set_error(Msg, Form)), []}
    end.

-spec form_test(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
form_test(State) ->
    Form = dui_redis_state:conn_form(State),
    case dui_redis_form:validate(Form) of
        ok ->
            Conn = dui_redis_form:to_connection(Form),
            S1 = dui_redis_state:set_test_result(State, <<"Testing...">>),
            S2 = dui_redis_state:set_screen(S1, test_connection),
            {dui_redis_state:set_loading(S2, true), [dui_redis_cmd:test_connection(Conn)]};
        {error, Msg} ->
            {set_form(State, dui_redis_form:set_error(Msg, Form)), []}
    end.

%% -- test connection --------------------------------------------------------

-spec test_key(#dui_state{}, term()) -> {#dui_state{}, [educkui_command:command()]}.
test_key(State, _Key) ->
    {dui_redis_state:set_screen(State, connection_form), []}.

%% -- confirm delete ---------------------------------------------------------

-spec confirm_key(#dui_state{}, term()) -> {#dui_state{}, [educkui_command:command()]}.
confirm_key(State, Key) when Key =:= <<"y">>; Key =:= enter ->
    do_delete(State);
confirm_key(State, _Key) ->
    S1 = dui_redis_state:clear_confirm(State),
    {dui_redis_state:set_screen(S1, connections), []}.

-spec do_delete(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
do_delete(State) ->
    case dui_redis_state:confirm(State) of
        {delete_connection, Conn} ->
            Id = maps:get(id, Conn, undefined),
            S1 = dui_redis_state:clear_confirm(State),
            {dui_redis_state:set_loading(S1, true), [dui_redis_cmd:delete_connection(State, Id)]};
        {delete_key, KeyMap} ->
            Key = maps:get(key, KeyMap),
            S1 = dui_redis_state:clear_confirm(State),
            S2 = record_history(S1, Key, <<"delete">>),
            {dui_redis_state:set_loading(S2, true), [dui_redis_cmd:delete_key(Key)]};
        flush_db ->
            S1 = dui_redis_state:clear_confirm(State),
            {dui_redis_state:set_loading(S1, true), [dui_redis_cmd:flush_db()]};
        _ ->
            {dui_redis_state:clear_confirm(State), []}
    end.

%% -- keys -------------------------------------------------------------------

-spec keys_screen_key(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
keys_screen_key(State, Key, Mods) ->
    case dui_redis_state:filter_active(State) of
        true -> filter_key(State, Key);
        false -> keys_nav_key(State, Key, Mods)
    end.

-spec keys_nav_key(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
keys_nav_key(State, Key, _Mods) when Key =:= <<"j">>; Key =:= down ->
    move_key(State, 1);
keys_nav_key(State, Key, _Mods) when Key =:= <<"k">>; Key =:= up ->
    move_key(State, -1);
keys_nav_key(State, page_down, _Mods) ->
    move_key(State, 10);
keys_nav_key(State, page_up, _Mods) ->
    move_key(State, -10);
keys_nav_key(State, <<"d">>, Mods) ->
    case lists:member(ctrl, Mods) of
        true -> move_key(State, 10);
        false -> {State, []}
    end;
keys_nav_key(State, <<"u">>, Mods) ->
    case lists:member(ctrl, Mods) of
        true -> move_key(State, -10);
        false -> start_history(State)
    end;
keys_nav_key(State, Key, _Mods) when Key =:= home; Key =:= <<"g">> ->
    select_key(State, 0);
keys_nav_key(State, Key, _Mods) when Key =:= 'end'; Key =:= <<"G">> ->
    Count = length(dui_redis_state:keys(State)),
    select_key(State, max(0, Count - 1));
keys_nav_key(State, enter, _Mods) ->
    open_detail(State);
keys_nav_key(State, <<"/">>, _Mods) ->
    start_filter(State);
keys_nav_key(State, <<"s">>, _Mods) ->
    cycle_sort(State);
keys_nav_key(State, <<"S">>, _Mods) ->
    toggle_sort(State);
keys_nav_key(State, <<"l">>, _Mods) ->
    load_more_keys(State);
keys_nav_key(State, <<"r">>, Mods) ->
    case lists:member(ctrl, Mods) of
        true -> start_prompt(State, regex);
        false -> reload_keys(State)
    end;
keys_nav_key(State, <<"f">>, Mods) ->
    case lists:member(ctrl, Mods) of
        true -> start_prompt(State, fuzzy);
        false -> confirm_flush_db(State)
    end;
keys_nav_key(State, <<"v">>, _Mods) ->
    start_prompt(State, search_value);
keys_nav_key(State, <<"F">>, _Mods) ->
    start_favorites(State);
keys_nav_key(State, <<"H">>, _Mods) ->
    start_recent(State);
keys_nav_key(State, <<"W">>, _Mods) ->
    start_tree(State);
keys_nav_key(State, <<"P">>, _Mods) ->
    start_templates(State);
keys_nav_key(State, <<"=">>, _Mods) ->
    start_prompt(State, compare);
keys_nav_key(State, <<"D">>, _Mods) ->
    start_switch_db(State);
keys_nav_key(State, _Key, _Mods) ->
    {State, []}.

-spec confirm_flush_db(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
confirm_flush_db(State) ->
    S1 = dui_redis_state:set_confirm(State, flush_db),
    {dui_redis_state:set_screen(S1, confirm_delete), []}.

-spec filter_key(#dui_state{}, term()) -> {#dui_state{}, [educkui_command:command()]}.
filter_key(State, enter) ->
    Edit = dui_redis_state:filter_edit(State),
    Pattern = normalize_pattern(educkui_lineedit:value(Edit)),
    S1 = dui_redis_state:set_filter_active(State, false),
    S2 = dui_redis_state:set_key_pattern(S1, Pattern),
    reload_keys(S2);
filter_key(State, esc) ->
    S1 = dui_redis_state:set_filter_active(State, false),
    {dui_redis_state:set_filter_edit(S1, undefined), []};
filter_key(State, Key) ->
    Edit0 = dui_redis_state:filter_edit(State),
    Edit1 = case Key of
        backspace -> educkui_lineedit:backspace(Edit0);
        delete -> educkui_lineedit:delete(Edit0);
        left -> educkui_lineedit:move(left, Edit0);
        right -> educkui_lineedit:move(right, Edit0);
        home -> educkui_lineedit:home(Edit0);
        'end' -> educkui_lineedit:'end'(Edit0);
        K when is_binary(K) -> educkui_lineedit:insert(K, Edit0);
        _ -> Edit0
    end,
    S1 = dui_redis_state:set_filter_edit(State, Edit1),
    {Seq, S2} = dui_redis_state:bump_search_seq(S1),
    Pattern = normalize_pattern(educkui_lineedit:value(Edit1)),
    {S2, [dui_redis_cmd:debounce_filter(State, Pattern, Seq)]}.

-spec start_filter(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_filter(State) ->
    Edit = educkui_lineedit:new(<<>>),
    S1 = dui_redis_state:set_filter_edit(State, Edit),
    {dui_redis_state:set_filter_active(S1, true), []}.

-spec switch_db_key(#dui_state{}, term()) -> {#dui_state{}, [educkui_command:command()]}.
switch_db_key(State, enter) ->
    Edit = dui_redis_state:db_input(State),
    case parse_int(educkui_lineedit:value(Edit)) of
        {ok, Db} ->
            {dui_redis_state:set_loading(State, true), [dui_redis_cmd:switch_db(State, Db)]};
        error ->
            {dui_redis_state:set_status(State, error, <<"Invalid database number">>), []}
    end;
switch_db_key(State, Key) ->
    Edit0 = dui_redis_state:db_input(State),
    Edit1 = case Key of
        backspace -> educkui_lineedit:backspace(Edit0);
        delete -> educkui_lineedit:delete(Edit0);
        left -> educkui_lineedit:move(left, Edit0);
        right -> educkui_lineedit:move(right, Edit0);
        home -> educkui_lineedit:home(Edit0);
        'end' -> educkui_lineedit:'end'(Edit0);
        K when is_binary(K) -> educkui_lineedit:insert(K, Edit0);
        _ -> Edit0
    end,
    {dui_redis_state:set_db_input(State, Edit1), []}.

-spec start_switch_db(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_switch_db(State) ->
    Db = case dui_redis_state:current_conn(State) of
        undefined -> 0;
        Conn -> maps:get(db, Conn, 0)
    end,
    Edit = educkui_lineedit:new(integer_to_binary(Db)),
    S1 = dui_redis_state:set_db_input(State, Edit),
    {dui_redis_state:set_screen(S1, switch_db), []}.

%% -- keys state transitions -------------------------------------------------

-spec reload_keys(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
reload_keys(State) ->
    Pattern = dui_redis_state:key_pattern(State),
    S1 = dui_redis_state:set_loading_keys(State, true),
    {S1, [dui_redis_cmd:load_keys(State, Pattern, 0, scan_size(State))]}.

-spec load_more_keys(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
load_more_keys(State) ->
    case dui_redis_state:key_cursor(State) of
        0 ->
            {State, []};
        Cursor ->
            Pattern = dui_redis_state:key_pattern(State),
            S1 = dui_redis_state:set_loading_keys(State, true),
            {S1, [dui_redis_cmd:load_keys(State, Pattern, Cursor, scan_size(State))]}
    end.

-spec move_key(#dui_state{}, integer()) -> {#dui_state{}, [educkui_command:command()]}.
move_key(State, Delta) ->
    Count = length(dui_redis_state:keys(State)),
    Current = dui_redis_state:selected_key(State),
    Target = max(0, min(max(0, Count - 1), Current + Delta)),
    select_key(State, Target).

-spec select_key(#dui_state{}, non_neg_integer()) ->
    {#dui_state{}, [educkui_command:command()]}.
select_key(State, Index) ->
    S1 = dui_redis_state:set_selected_key(State, Index),
    load_selected_preview(S1).

-spec load_selected_preview(#dui_state{}) ->
    {#dui_state{}, [educkui_command:command()]}.
load_selected_preview(State) ->
    case selected_key_map(State) of
        undefined ->
            {dui_redis_state:set_preview(State, <<>>, undefined), []};
        #{key := Key} ->
            S1 = dui_redis_state:set_preview(State, Key, undefined),
            {S1, [dui_redis_cmd:load_preview(State, Key)]}
    end.

-spec open_detail(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
open_detail(State) ->
    case selected_key_map(State) of
        undefined ->
            {State, []};
        #{key := Key} = KeyMap ->
            S1 = dui_redis_state:set_current_key(State, KeyMap),
            S2 = dui_redis_state:set_current_value(S1, undefined),
            S3 = dui_redis_state:set_detail_scroll(S2, 0),
            {dui_redis_state:set_screen(S3, key_detail),
             [dui_redis_cmd:load_detail(State, Key)]}
    end.

-spec selected_key_map(#dui_state{}) -> map() | undefined.
selected_key_map(State) ->
    case dui_redis_state:keys(State) of
        [] -> undefined;
        Keys ->
            Index = min(dui_redis_state:selected_key(State), length(Keys) - 1),
            lists:nth(Index + 1, Keys)
    end.

-spec cycle_sort(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
cycle_sort(State) ->
    Next = case dui_redis_state:sort_by(State) of
        key -> type;
        type -> ttl;
        ttl -> key
    end,
    apply_sort(dui_redis_state:set_sort_by(State, Next)).

-spec toggle_sort(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
toggle_sort(State) ->
    apply_sort(dui_redis_state:toggle_sort_asc(State)).

-spec apply_sort(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
apply_sort(State) ->
    load_selected_preview(clamp_selected(sort_state_keys(State))).

-spec sort_state_keys(#dui_state{}) -> #dui_state{}.
sort_state_keys(State) ->
    Sorted = dui_redis_type:sort_keys(
        dui_redis_state:keys(State),
        dui_redis_state:sort_by(State),
        dui_redis_state:sort_asc(State)),
    dui_redis_state:replace_keys(State, Sorted).

-spec clamp_selected(#dui_state{}) -> #dui_state{}.
clamp_selected(State) ->
    Count = length(dui_redis_state:keys(State)),
    Index = min(dui_redis_state:selected_key(State), max(0, Count - 1)),
    dui_redis_state:set_selected_key(State, Index).

-spec scan_size(#dui_state{}) -> pos_integer().
scan_size(State) ->
    case maps:get(scan_size, dui_redis_state:cli(State), 1000) of
        N when is_integer(N), N > 0 -> N;
        _ -> 1000
    end.

-spec normalize_pattern(binary()) -> binary().
normalize_pattern(<<>>) ->
    <<"*">>;
normalize_pattern(Raw) ->
    case binary:match(Raw, [<<"*">>, <<"?">>, <<"[">>, <<"]">>]) of
        nomatch -> <<"*", Raw/binary, "*">>;
        _ -> Raw
    end.

-spec parse_int(binary()) -> {ok, integer()} | error.
parse_int(Bin) ->
    try {ok, binary_to_integer(string:trim(Bin))}
    catch error:badarg -> error
    end.

-spec parse_number(binary()) -> {ok, number()} | error.
parse_number(Bin) ->
    Trimmed = string:trim(Bin),
    try {ok, binary_to_float(Trimmed)}
    catch error:badarg ->
        try {ok, binary_to_integer(Trimmed)}
        catch error:badarg -> error
        end
    end.

-spec number_or(binary(), number()) -> number().
number_or(Bin, Default) ->
    case parse_number(Bin) of
        {ok, N} -> N;
        error -> Default
    end.

%% -- key detail / editing ---------------------------------------------------

-spec find_key_map(#dui_state{}, binary()) -> map().
find_key_map(State, Key) ->
    case [K || K <- dui_redis_state:keys(State), maps:get(key, K, undefined) =:= Key] of
        [K | _] -> K;
        [] -> #{key => Key, type => string, ttl => -1}
    end.

-spec current_type(#dui_state{}) -> atom().
current_type(State) ->
    case dui_redis_state:current_value(State) of
        undefined -> string;
        Value -> maps:get(type, Value, string)
    end.

-spec refresh_detail(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
refresh_detail(State) ->
    case dui_redis_state:current_key(State) of
        undefined -> {State, []};
        KeyMap ->
            Key = maps:get(key, KeyMap),
            {State, [dui_redis_cmd:load_detail(State, Key)]}
    end.

-spec record_history(#dui_state{}, binary(), binary()) -> #dui_state{}.
record_history(State, Key, Action) ->
    case dui_redis_state:current_value(State) of
        undefined -> State;
        Value ->
            Hist = dui_redis_state:history(State),
            dui_redis_state:set_history(State,
                dui_redis_history:add(Hist, Key, Value, Action))
    end.

-spec detail_key(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
detail_key(State, Key, Mods) ->
    case Key of
        K when K =:= <<"j">>; K =:= down -> scroll_detail(State, 1);
        K when K =:= <<"k">>; K =:= up -> scroll_detail(State, -1);
        page_down -> scroll_detail(State, 20);
        page_up -> scroll_detail(State, -20);
        <<"d">> -> maybe_ctrl_scroll(State, Mods, 20, confirm_delete_key(State));
        <<"u">> -> maybe_ctrl_scroll(State, Mods, -20, start_history_for_current(State));
        <<"r">> -> refresh_detail(State);
        <<"e">> -> start_edit(State);
        <<"t">> -> start_prompt(State, ttl);
        <<"R">> -> start_prompt(State, rename);
        <<"c">> -> start_prompt(State, copy);
        <<"a">> -> start_prompt(State, collection_add);
        <<"x">> -> start_prompt(State, collection_remove);
        <<"J">> -> start_prompt(State, json_path);
        <<"F">> -> add_current_favorite(State);
        delete -> confirm_delete_key(State);
        backspace -> confirm_delete_key(State);
        _ -> {State, []}
    end.

-spec maybe_ctrl_scroll(#dui_state{}, [atom()], integer(),
                       {#dui_state{}, [educkui_command:command()]}) ->
    {#dui_state{}, [educkui_command:command()]}.
maybe_ctrl_scroll(State, Mods, Delta, Fallback) ->
    case lists:member(ctrl, Mods) of
        true -> scroll_detail(State, Delta);
        false -> Fallback
    end.

-spec scroll_detail(#dui_state{}, integer()) ->
    {#dui_state{}, [educkui_command:command()]}.
scroll_detail(State, Delta) ->
    Current = dui_redis_state:detail_scroll(State),
    {dui_redis_state:set_detail_scroll(State, max(0, Current + Delta)), []}.

-spec confirm_delete_key(#dui_state{}) ->
    {#dui_state{}, [educkui_command:command()]}.
confirm_delete_key(State) ->
    case dui_redis_state:current_key(State) of
        undefined ->
            {State, []};
        KeyMap ->
            S1 = dui_redis_state:set_confirm(State, {delete_key, KeyMap}),
            {dui_redis_state:set_screen(S1, confirm_delete), []}
    end.

%% -- value editing ----------------------------------------------------------

-spec start_edit(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_edit(State) ->
    Value = dui_redis_state:current_value(State),
    Type = current_type(State),
    case Type =:= string orelse Type =:= json of
        false ->
            {dui_redis_state:set_status(State, info,
                <<"Use 'a'/'x' to edit collection items">>), []};
        true ->
            Text = case Value of
                undefined -> <<>>;
                _ -> maps:get(text, Value, <<>>)
            end,
            Editor = dui_redis_editor:new(Text),
            S1 = dui_redis_state:set_editor(State, Editor),
            {dui_redis_state:set_screen(S1, edit_value), []}
    end.

-spec editor_key(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
editor_key(State, <<"s">>, Mods) ->
    case lists:member(ctrl, Mods) of
        true -> save_editor(State);
        false -> editor_edit(State, <<"s">>)
    end;
editor_key(State, f2, _Mods) ->
    %% Ctrl+S is sometimes swallowed by terminal flow control; F2 is a fallback.
    save_editor(State);
editor_key(State, Key, _Mods) ->
    editor_edit(State, Key).

-spec editor_edit(#dui_state{}, term()) -> {#dui_state{}, [educkui_command:command()]}.
editor_edit(State, Key) ->
    Editor = dui_redis_state:editor(State),
    Editor1 = case Key of
        enter -> dui_redis_editor:newline(Editor);
        backspace -> dui_redis_editor:backspace(Editor);
        delete -> dui_redis_editor:delete(Editor);
        left -> dui_redis_editor:move(left, Editor);
        right -> dui_redis_editor:move(right, Editor);
        up -> dui_redis_editor:move(up, Editor);
        down -> dui_redis_editor:move(down, Editor);
        home -> dui_redis_editor:home(Editor);
        'end' -> dui_redis_editor:'end'(Editor);
        tab -> dui_redis_editor:insert(<<"  ">>, Editor);
        K when is_binary(K) -> dui_redis_editor:insert(K, Editor);
        _ -> Editor
    end,
    {dui_redis_state:set_editor(State, Editor1), []}.

-spec save_editor(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
save_editor(State) ->
    Editor = dui_redis_state:editor(State),
    Text = dui_redis_editor:value(Editor),
    KeyMap = dui_redis_state:current_key(State),
    Key = maps:get(key, KeyMap, <<>>),
    Type = current_type(State),
    Fun = case Type of
        json -> fun() -> dui_redis_client:json_set(Key, Text) end;
        _ -> fun() -> dui_redis_client:set_string(Key, Text, 0) end
    end,
    S1 = record_history(State, Key, <<"set">>),
    {S1, [dui_redis_cmd:write(value_saved, Fun)]}.

%% -- generic prompt ---------------------------------------------------------

-spec start_prompt(#dui_state{}, atom()) ->
    {#dui_state{}, [educkui_command:command()]}.
start_prompt(State, rename) ->
    KeyMap = dui_redis_state:current_key(State),
    Key = maps:get(key, KeyMap, <<>>),
    Prompt = dui_redis_prompt:new([{name, <<"New key name">>, false}], #{name => Key}),
    open_prompt(State, Prompt, {rename, KeyMap});
start_prompt(State, copy) ->
    KeyMap = dui_redis_state:current_key(State),
    Key = maps:get(key, KeyMap, <<>>),
    Prompt = dui_redis_prompt:new([{name, <<"Destination key">>, false}],
                                  #{name => <<Key/binary, ":copy">>}),
    open_prompt(State, Prompt, {copy, KeyMap});
start_prompt(State, ttl) ->
    KeyMap = dui_redis_state:current_key(State),
    Prompt = dui_redis_prompt:new([{ttl, <<"TTL seconds (-1 to remove)">>, false}],
                                  #{ttl => <<>>}),
    open_prompt(State, Prompt, {ttl, KeyMap});
start_prompt(State, regex) ->
    Prompt = dui_redis_prompt:new([{pattern, <<"Regex">>, false}]),
    open_prompt(State, Prompt, {regex, undefined});
start_prompt(State, fuzzy) ->
    Prompt = dui_redis_prompt:new([{term, <<"Fuzzy term">>, false}]),
    open_prompt(State, Prompt, {fuzzy, undefined});
start_prompt(State, search_value) ->
    Prompt = dui_redis_prompt:new([{pattern, <<"Key pattern">>, false},
                                   {search, <<"Value contains">>, false}]),
    open_prompt(State, Prompt, {search_value, undefined});
start_prompt(State, compare) ->
    Prompt = dui_redis_prompt:new([{k1, <<"First key">>, false},
                                   {k2, <<"Second key">>, false}]),
    open_prompt(State, Prompt, {compare, undefined});
start_prompt(State, json_path) ->
    KeyMap = dui_redis_state:current_key(State),
    Prompt = dui_redis_prompt:new([{path, <<"JSONPath (e.g. $.name)">>, false}],
                                  #{path => <<"$">>}),
    open_prompt(State, Prompt, {json_path, KeyMap});
start_prompt(State, Action) when Action =:= collection_add;
                                 Action =:= collection_remove ->
    KeyMap = dui_redis_state:current_key(State),
    Type = current_type(State),
    Kind = case Action of
        collection_add -> add;
        collection_remove -> remove
    end,
    Fields = collection_fields(Type, Kind),
    Prompt = dui_redis_prompt:new(Fields),
    open_prompt(State, Prompt, {Action, KeyMap, Type}).

-spec open_prompt(#dui_state{}, dui_redis_prompt:prompt(), term()) ->
    {#dui_state{}, [educkui_command:command()]}.
open_prompt(State, Prompt, Purpose) ->
    S1 = dui_redis_state:set_prompt(State, Prompt),
    S2 = dui_redis_state:set_prompt_purpose(S1, Purpose),
    {dui_redis_state:set_screen(S2, prompt), []}.

-spec prompt_key(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
prompt_key(State, tab, Mods) ->
    Prompt = dui_redis_state:prompt(State),
    Prompt1 = case lists:member(shift, Mods) of
        true -> dui_redis_prompt:focus_prev(Prompt);
        false -> dui_redis_prompt:focus_next(Prompt)
    end,
    {dui_redis_state:set_prompt(State, Prompt1), []};
prompt_key(State, down, _Mods) ->
    prompt_focus(State, next);
prompt_key(State, up, _Mods) ->
    prompt_focus(State, prev);
prompt_key(State, enter, _Mods) ->
    submit_prompt(State);
prompt_key(State, Key, Mods) ->
    prompt_edit(State, Key, Mods).

-spec prompt_focus(#dui_state{}, next | prev) ->
    {#dui_state{}, [educkui_command:command()]}.
prompt_focus(State, Dir) ->
    Prompt = dui_redis_state:prompt(State),
    Prompt1 = case Dir of
        next -> dui_redis_prompt:focus_next(Prompt);
        prev -> dui_redis_prompt:focus_prev(Prompt)
    end,
    {dui_redis_state:set_prompt(State, Prompt1), []}.

-spec prompt_edit(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
prompt_edit(State, Key, Mods) ->
    Prompt = dui_redis_state:prompt(State),
    Prompt1 = case Key of
        backspace -> dui_redis_prompt:backspace(Prompt);
        delete -> dui_redis_prompt:delete(Prompt);
        left -> dui_redis_prompt:move(left, Prompt);
        right -> dui_redis_prompt:move(right, Prompt);
        home -> dui_redis_prompt:home(Prompt);
        'end' -> dui_redis_prompt:'end'(Prompt);
        <<" ">> -> dui_redis_prompt:insert(<<" ">>, Prompt);
        K when is_binary(K), Mods =:= [] -> dui_redis_prompt:insert(K, Prompt);
        K when is_binary(K) ->
            case has_ctrl_like(Mods) of
                true -> Prompt;
                false -> dui_redis_prompt:insert(K, Prompt)
            end;
        _ -> Prompt
    end,
    {dui_redis_state:set_prompt(State, Prompt1), []}.

-spec submit_prompt(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
submit_prompt(State) ->
    Purpose = dui_redis_state:prompt_purpose(State),
    Prompt = dui_redis_state:prompt(State),
    Values = dui_redis_prompt:to_map(Prompt),
    {Screen, Commands} = prompt_action(Purpose, Values),
    S1 = dui_redis_state:set_prompt(State, undefined),
    S2 = dui_redis_state:set_screen(S1, Screen),
    {S2, Commands}.

-spec prompt_action(term(), map()) -> {atom(), [educkui_command:command()]}.
prompt_action({rename, KeyMap}, Values) ->
    Old = maps:get(key, KeyMap),
    New = maps:get(name, Values, <<>>),
    {key_detail, [dui_redis_cmd:write(key_renamed,
        fun() -> dui_redis_client:rename_key(Old, New) end)]};
prompt_action({copy, KeyMap}, Values) ->
    Src = maps:get(key, KeyMap),
    Dst = maps:get(name, Values, <<>>),
    {key_detail, [dui_redis_cmd:write(key_copied,
        fun() -> dui_redis_client:copy_key(Src, Dst, false) end)]};
prompt_action({ttl, KeyMap}, Values) ->
    Key = maps:get(key, KeyMap),
    Seconds = case parse_int(maps:get(ttl, Values, <<>>)) of
        {ok, N} -> N;
        error -> 0
    end,
    {key_detail, [dui_redis_cmd:write(ttl_set,
        fun() -> dui_redis_client:set_ttl(Key, Seconds) end)]};
prompt_action({collection_add, KeyMap, Type}, Values) ->
    Key = maps:get(key, KeyMap),
    {key_detail, [dui_redis_cmd:write(collection_added,
        collection_fun(Type, add, Key, Values))]};
prompt_action({collection_remove, KeyMap, Type}, Values) ->
    Key = maps:get(key, KeyMap),
    {key_detail, [dui_redis_cmd:write(collection_removed,
        collection_fun(Type, remove, Key, Values))]};
prompt_action({regex, _}, Values) ->
    {keys, [dui_redis_cmd:regex_search(maps:get(pattern, Values, <<>>), 100)]};
prompt_action({fuzzy, _}, Values) ->
    {keys, [dui_redis_cmd:fuzzy_search(maps:get(term, Values, <<>>), 100)]};
prompt_action({search_value, _}, Values) ->
    {keys, [dui_redis_cmd:search_by_value(maps:get(pattern, Values, <<>>),
                                          maps:get(search, Values, <<>>), 100)]};
prompt_action({compare, _}, Values) ->
    {keys, [dui_redis_cmd:compare_keys(maps:get(k1, Values, <<>>),
                                       maps:get(k2, Values, <<>>))]};
prompt_action({json_path, KeyMap}, Values) ->
    Key = maps:get(key, KeyMap),
    {key_detail, [dui_redis_cmd:json_get_path(Key, maps:get(path, Values, <<>>))]}.

-spec collection_fun(atom(), add | remove, binary(), map()) -> fun(() -> term()).
collection_fun(list, add, Key, V) ->
    fun() -> dui_redis_client:list_push(Key, maps:get(value, V)) end;
collection_fun(list, remove, Key, V) ->
    fun() -> dui_redis_client:list_remove(Key, maps:get(value, V)) end;
collection_fun(set, add, Key, V) ->
    fun() -> dui_redis_client:set_add(Key, maps:get(member, V)) end;
collection_fun(set, remove, Key, V) ->
    fun() -> dui_redis_client:set_remove(Key, maps:get(member, V)) end;
collection_fun(zset, add, Key, V) ->
    Score = number_or(maps:get(score, V, <<"0">>), 0),
    fun() -> dui_redis_client:zset_add(Key, Score, maps:get(member, V)) end;
collection_fun(zset, remove, Key, V) ->
    fun() -> dui_redis_client:zset_remove(Key, maps:get(member, V)) end;
collection_fun(hash, add, Key, V) ->
    fun() -> dui_redis_client:hash_set(Key, maps:get(field, V), maps:get(value, V)) end;
collection_fun(hash, remove, Key, V) ->
    fun() -> dui_redis_client:hash_delete(Key, maps:get(field, V)) end;
collection_fun(stream, add, Key, V) ->
    fun() -> dui_redis_client:stream_add(Key, [{maps:get(field, V), maps:get(value, V)}]) end;
collection_fun(stream, remove, Key, V) ->
    fun() -> dui_redis_client:stream_delete(Key, maps:get(id, V)) end;
collection_fun(geo, add, Key, V) ->
    fun() ->
        dui_redis_client:q([<<"GEOADD">>, Key, maps:get(lon, V),
                            maps:get(lat, V), maps:get(member, V)])
    end;
collection_fun(geo, remove, Key, V) ->
    fun() -> dui_redis_client:zset_remove(Key, maps:get(member, V)) end;
collection_fun(hll, add, Key, V) ->
    fun() -> dui_redis_client:q([<<"PFADD">>, Key, maps:get(element, V)]) end;
collection_fun(bitmap, add, Key, V) ->
    fun() ->
        dui_redis_client:q([<<"SETBIT">>, Key, maps:get(offset, V), maps:get(value, V)])
    end;
collection_fun(_Type, _Action, _Key, _V) ->
    fun() -> {error, unsupported} end.

-spec collection_fields(atom(), add | remove) -> [dui_redis_prompt:field()].
collection_fields(list, _) -> [{value, <<"Value">>, false}];
collection_fields(set, _) -> [{member, <<"Member">>, false}];
collection_fields(zset, add) ->
    [{member, <<"Member">>, false}, {score, <<"Score">>, false}];
collection_fields(zset, remove) -> [{member, <<"Member">>, false}];
collection_fields(hash, _) ->
    [{field, <<"Field">>, false}, {value, <<"Value">>, false}];
collection_fields(stream, add) ->
    [{field, <<"Field">>, false}, {value, <<"Value">>, false}];
collection_fields(stream, remove) -> [{id, <<"Entry ID">>, false}];
collection_fields(geo, add) ->
    [{member, <<"Member">>, false}, {lon, <<"Longitude">>, false},
     {lat, <<"Latitude">>, false}];
collection_fields(geo, remove) -> [{member, <<"Member">>, false}];
collection_fields(hll, _) -> [{element, <<"Element">>, false}];
collection_fields(bitmap, _) ->
    [{offset, <<"Bit offset">>, false}, {value, <<"Bit (0/1)">>, false}];
collection_fields(_Type, _Action) -> [{value, <<"Value">>, false}].

%% -- lists / tree (M4) ------------------------------------------------------

-spec start_favorites(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_favorites(State) ->
    S1 = dui_redis_state:set_loading(State, true),
    {S1, [dui_redis_cmd:load_favorites(State)]}.

-spec start_recent(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_recent(State) ->
    S1 = dui_redis_state:set_loading(State, true),
    {S1, [dui_redis_cmd:load_recent(State)]}.

-spec start_templates(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_templates(State) ->
    S1 = dui_redis_state:set_loading(State, true),
    {S1, [dui_redis_cmd:load_templates(State)]}.

-spec start_tree(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_tree(State) ->
    Keys = [maps:get(key, K, <<>>) || K <- dui_redis_state:keys(State)],
    Nodes = dui_redis_tree:build(Keys, <<":">>),
    S1 = dui_redis_state:set_tree_nodes(State, Nodes),
    {dui_redis_state:set_screen(S1, tree), []}.

-spec start_history(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_history(State) ->
    case selected_key_map(State) of
        undefined -> {State, []};
        #{key := Key} -> show_history(State, Key)
    end.

-spec start_history_for_current(#dui_state{}) ->
    {#dui_state{}, [educkui_command:command()]}.
start_history_for_current(State) ->
    case dui_redis_state:current_key(State) of
        undefined -> {State, []};
        KeyMap -> show_history(State, maps:get(key, KeyMap, <<>>))
    end.

-spec show_history(#dui_state{}, binary()) -> {#dui_state{}, [educkui_command:command()]}.
show_history(State, Key) ->
    Entries = dui_redis_history:entries(dui_redis_state:history(State), Key),
    S1 = dui_redis_state:set_results(State, Entries, {<<"Value History">>, history}),
    {dui_redis_state:set_screen(S1, results), []}.

-spec add_current_favorite(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
add_current_favorite(State) ->
    case dui_redis_state:current_key(State) of
        undefined ->
            {State, []};
        KeyMap ->
            Key = maps:get(key, KeyMap),
            {State, [dui_redis_cmd:add_favorite(State, Key, <<>>)]}
    end.

%% -- results screen ---------------------------------------------------------

-spec results_key(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
results_key(State, Key, Mods) ->
    case Key of
        K when K =:= <<"j">>; K =:= down -> move_result(State, 1);
        K when K =:= <<"k">>; K =:= up -> move_result(State, -1);
        page_down -> move_result(State, 10);
        page_up -> move_result(State, -10);
        K when K =:= home; K =:= <<"g">> -> set_result_index(State, 0);
        K when K =:= 'end'; K =:= <<"G">> ->
            set_result_index(State, max(0, length(dui_redis_state:results(State)) - 1));
        enter -> open_result(State);
        <<"d">> -> remove_result_item(State, Mods);
        _ -> {State, []}
    end.

-spec move_result(#dui_state{}, integer()) -> {#dui_state{}, [educkui_command:command()]}.
move_result(State, Delta) ->
    Count = length(dui_redis_state:results(State)),
    Current = dui_redis_state:selected_result(State),
    Target = max(0, min(max(0, Count - 1), Current + Delta)),
    set_result_index(State, Target).

-spec set_result_index(#dui_state{}, non_neg_integer()) ->
    {#dui_state{}, [educkui_command:command()]}.
set_result_index(State, Index) ->
    {dui_redis_state:set_selected_result(State, Index), []}.

-spec open_result(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
open_result(State) ->
    case selected_result_map(State) of
        undefined ->
            {State, []};
        Entry ->
            case dui_redis_state:results_purpose(State) of
                templates ->
                    Msg = <<"Template ", (to_bin(maps:get(name, Entry, <<>>)))/binary,
                            ": ", (to_bin(maps:get(key_pattern, Entry, <<>>)))/binary>>,
                    {dui_redis_state:set_status(State, info, Msg), []};
                history ->
                    Value = maps:get(value, Entry, #{}),
                    Text = join_lines(dui_redis_preview:lines(Value, 200)),
                    S1 = dui_redis_state:set_result_text(State, Text),
                    {dui_redis_state:set_screen(S1, result_text), []};
                _ ->
                    open_key_detail(State, maps:get(key, Entry, <<>>))
            end
    end.

-spec remove_result_item(#dui_state{}, [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
remove_result_item(State, _Mods) ->
    case {dui_redis_state:results_purpose(State), selected_result_map(State)} of
        {favorites, Entry} ->
            {State, [dui_redis_cmd:remove_favorite(State, maps:get(key, Entry, <<>>))]};
        _ ->
            {State, []}
    end.

-spec selected_result_map(#dui_state{}) -> map() | undefined.
selected_result_map(State) ->
    case dui_redis_state:results(State) of
        [] -> undefined;
        Results ->
            Index = min(dui_redis_state:selected_result(State), length(Results) - 1),
            lists:nth(Index + 1, Results)
    end.

-spec open_key_detail(#dui_state{}, binary()) ->
    {#dui_state{}, [educkui_command:command()]}.
open_key_detail(State, Key) ->
    KeyMap = find_key_map(State, Key),
    S1 = dui_redis_state:set_current_key(State, KeyMap),
    S2 = dui_redis_state:set_current_value(S1, undefined),
    S3 = dui_redis_state:set_detail_scroll(S2, 0),
    S4 = dui_redis_state:set_screen(S3, key_detail),
    Type = to_bin(maps:get(type, KeyMap, string)),
    {S4, [dui_redis_cmd:load_detail(State, Key),
          dui_redis_cmd:add_recent(State, Key, Type)]}.

%% -- tree screen ------------------------------------------------------------

-spec tree_key(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
tree_key(State, Key, _Mods) ->
    Flat = flattened_tree(State),
    Count = length(Flat),
    Sel = min(dui_redis_state:selected_tree(State), max(0, Count - 1)),
    case Key of
        K when K =:= <<"j">>; K =:= down ->
            {dui_redis_state:set_selected_tree(State, min(max(0, Count - 1), Sel + 1)), []};
        K when K =:= <<"k">>; K =:= up ->
            {dui_redis_state:set_selected_tree(State, max(0, Sel - 1)), []};
        right -> tree_toggle(State, Flat, Sel);
        left -> tree_collapse(State, Flat, Sel);
        enter -> tree_activate(State, Flat, Sel);
        _ -> {State, []}
    end.

-spec flattened_tree(#dui_state{}) -> [{non_neg_integer(), map()}].
flattened_tree(State) ->
    dui_redis_tree:flatten(dui_redis_state:tree_nodes(State),
                           dui_redis_state:tree_expanded(State)).

-spec node_at([{non_neg_integer(), map()}], non_neg_integer()) -> map() | undefined.
node_at([], _Index) -> undefined;
node_at(Flat, Index) ->
    element(2, lists:nth(min(Index + 1, length(Flat)), Flat)).

-spec tree_toggle(#dui_state{}, [{non_neg_integer(), map()}], non_neg_integer()) ->
    {#dui_state{}, [educkui_command:command()]}.
tree_toggle(State, Flat, Sel) ->
    case node_at(Flat, Sel) of
        #{path := Path} = Node ->
            case maps:get(children, Node, []) of
                [] -> {State, []};
                _ ->
                    S1 = dui_redis_state:toggle_tree_expanded(State, Path),
                    {S1, []}
            end;
        undefined ->
            {State, []}
    end.

-spec tree_collapse(#dui_state{}, [{non_neg_integer(), map()}], non_neg_integer()) ->
    {#dui_state{}, [educkui_command:command()]}.
tree_collapse(State, Flat, Sel) ->
    case node_at(Flat, Sel) of
        #{path := Path} ->
            case lists:member(Path, dui_redis_state:tree_expanded(State)) of
                true -> {dui_redis_state:toggle_tree_expanded(State, Path), []};
                false -> {State, []}
            end;
        undefined ->
            {State, []}
    end.

-spec tree_activate(#dui_state{}, [{non_neg_integer(), map()}], non_neg_integer()) ->
    {#dui_state{}, [educkui_command:command()]}.
tree_activate(State, Flat, Sel) ->
    case node_at(Flat, Sel) of
        undefined ->
            {State, []};
        Node ->
            case maps:get(children, Node, []) of
                [] ->
                    case maps:get(is_key, Node, false) of
                        true -> open_key_detail(State, maps:get(path, Node));
                        false -> {State, []}
                    end;
                _ ->
                    {dui_redis_state:toggle_tree_expanded(State, maps:get(path, Node)), []}
            end
    end.

-spec join_lines([binary()]) -> binary().
join_lines(Lines) ->
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

-spec build_compare_text(map(), map(), binary()) -> binary().
build_compare_text(V1, V2, Diff) ->
    L1 = join_lines(dui_redis_preview:lines(V1, 200)),
    L2 = join_lines(dui_redis_preview:lines(V2, 200)),
    <<"Key 1:\n", L1/binary, "\n\nKey 2:\n", L2/binary, "\n\nDiff:\n", Diff/binary>>.

%% ---------------------------------------------------------------------------
%% State transitions
%% ---------------------------------------------------------------------------

-spec maybe_auto_connect(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
maybe_auto_connect(State) ->
    case maps:get(connection, dui_redis_state:cli(State), undefined) of
        Conn when is_map(Conn) ->
            start_connect(State, Conn);
        _ ->
            {State, []}
    end.

-spec start_connect(#dui_state{}, map()) -> {#dui_state{}, [educkui_command:command()]}.
start_connect(State, Conn) ->
    S1 = dui_redis_state:set_current_conn(State, Conn),
    S2 = dui_redis_state:set_connection_error(S1, undefined),
    S3 = dui_redis_state:set_status(S2, info, <<"Connecting...">>),
    S4 = dui_redis_state:set_loading(S3, true),
    {S4, [dui_redis_cmd:connect(Conn)]}.

-spec finish_form(#dui_state{}, map(), binary()) ->
    {#dui_state{}, [educkui_command:command()]}.
finish_form(State, Conn, Message) ->
    S1 = dui_redis_state:upsert_connection(State, Conn),
    S2 = dui_redis_state:set_screen(S1, connections),
    S3 = dui_redis_state:set_conn_form(S2, #{}),
    S4 = dui_redis_state:set_editing_conn(S3, undefined),
    S5 = dui_redis_state:set_loading(S4, false),
    {dui_redis_state:set_status(S5, info, Message), []}.

-spec form_error(#dui_state{}, term()) -> {#dui_state{}, [educkui_command:command()]}.
form_error(State, Reason) ->
    Form = dui_redis_form:set_error(error_text(Reason), dui_redis_state:conn_form(State)),
    {set_form(dui_redis_state:set_loading(State, false), Form), []}.

-spec update_test_result(#dui_state{}, term()) ->
    {#dui_state{}, [educkui_command:command()]}.
update_test_result(State, {ok, Ms}) ->
    Msg = iolist_to_binary(io_lib:format("Connected in ~bms", [Ms])),
    S1 = dui_redis_state:set_screen(State, test_connection),
    S2 = dui_redis_state:set_loading(S1, false),
    {dui_redis_state:set_test_result(S2, Msg), []};
update_test_result(State, {error, Reason}) ->
    Msg = <<"Failed: ", (error_text(Reason))/binary>>,
    S1 = dui_redis_state:set_screen(State, test_connection),
    S2 = dui_redis_state:set_loading(S1, false),
    {dui_redis_state:set_test_result(S2, Msg), []}.

-spec open_add_form(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
open_add_form(State) ->
    S1 = dui_redis_state:set_conn_form(State, dui_redis_form:new_add()),
    S2 = dui_redis_state:set_editing_conn(S1, undefined),
    S3 = dui_redis_state:set_test_result(S2, undefined),
    {dui_redis_state:set_screen(S3, connection_form), []}.

-spec open_edit_form(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
open_edit_form(State) ->
    case selected_conn(State) of
        undefined ->
            {State, []};
        Conn ->
            S1 = dui_redis_state:set_conn_form(State, dui_redis_form:new_edit(Conn)),
            S2 = dui_redis_state:set_editing_conn(S1, Conn),
            S3 = dui_redis_state:set_test_result(S2, undefined),
            {dui_redis_state:set_screen(S3, connection_form), []}
    end.

-spec cancel_form(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
cancel_form(State) ->
    S1 = dui_redis_state:set_conn_form(State, #{}),
    S2 = dui_redis_state:set_editing_conn(S1, undefined),
    {dui_redis_state:set_screen(S2, connections), []}.

-spec connect_selected(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
connect_selected(State) ->
    case selected_conn(State) of
        undefined -> {State, []};
        Conn -> start_connect(State, Conn)
    end.

-spec open_confirm_delete(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
open_confirm_delete(State) ->
    case selected_conn(State) of
        undefined ->
            {State, []};
        Conn ->
            S1 = dui_redis_state:set_confirm(State, {delete_connection, Conn}),
            {dui_redis_state:set_screen(S1, confirm_delete), []}
    end.

-spec move_selected(#dui_state{}, integer()) -> #dui_state{}.
move_selected(State, Delta) ->
    Count = length(dui_redis_state:connections(State)),
    case Count of
        0 -> dui_redis_state:set_selected(State, 0);
        _ ->
            Current = dui_redis_state:selected(State),
            New = max(0, min(Count - 1, Current + Delta)),
            dui_redis_state:set_selected(State, New)
    end.

-spec selected_conn(#dui_state{}) -> map() | undefined.
selected_conn(State) ->
    Conns = dui_redis_state:connections(State),
    case length(Conns) of
        0 -> undefined;
        N ->
            Index = min(dui_redis_state:selected(State), N - 1),
            lists:nth(Index + 1, Conns)
    end.

-spec set_form(#dui_state{}, map()) -> #dui_state{}.
set_form(State, Form) ->
    dui_redis_state:set_conn_form(State, Form).

-spec field_type(map()) -> atom().
field_type(Form) ->
    maps:get(type, dui_redis_form:focused_field(Form)).

-spec has_ctrl_like([atom()]) -> boolean().
has_ctrl_like(Mods) ->
    lists:any(fun(M) -> lists:member(M, [ctrl, alt, meta]) end, Mods).

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
    Screen = screen_title(State),
    Version = list_to_binary(?DUI_REDIS_VERSION),
    Text = <<" dui-redis ", Version/binary, "  |  ", Screen/binary>>,
    educkui_render_node:height(
        educkui_render_node:text(Text, dui_redis_theme:title()), 1).

-spec screen_title(#dui_state{}) -> binary().
screen_title(#dui_state{screen = connection_form, conn_form = Form}) ->
    case maps:get(mode, Form, add) of
        edit -> <<"Edit Connection">>;
        _ -> <<"Add Connection">>
    end;
screen_title(State) ->
    dui_redis_fmt:screen_name(dui_redis_state:screen(State)).

-spec body(#dui_state{}) -> #dui_node{}.
body(State) ->
    case dui_redis_state:show_help(State) of
        true -> help_view();
        false -> screen_view(State)
    end.

-spec screen_view(#dui_state{}) -> #dui_node{}.
screen_view(#dui_state{screen = connections} = State) ->
    connections_view(State);
screen_view(#dui_state{screen = connection_form} = State) ->
    form_view(State);
screen_view(#dui_state{screen = test_connection} = State) ->
    test_view(State);
screen_view(#dui_state{screen = confirm_delete} = State) ->
    educkui_render_node:overlay([
        connections_view(State),
        confirm_view(State)
    ]);
screen_view(#dui_state{screen = keys} = State) ->
    keys_view(State);
screen_view(#dui_state{screen = key_detail} = State) ->
    detail_view(State);
screen_view(#dui_state{screen = edit_value} = State) ->
    editor_view(State);
screen_view(#dui_state{screen = prompt} = State) ->
    prompt_view(State);
screen_view(#dui_state{screen = results} = State) ->
    results_view(State);
screen_view(#dui_state{screen = tree} = State) ->
    tree_view(State);
screen_view(#dui_state{screen = result_text} = State) ->
    result_text_view(State);
screen_view(#dui_state{screen = switch_db} = State) ->
    switch_db_view(State);
screen_view(_State) ->
    educkui_render_node:empty().

%% -- connections ------------------------------------------------------------

-spec connections_view(#dui_state{}) -> #dui_node{}.
connections_view(State) ->
    Conns = dui_redis_state:connections(State),
    Header = iolist_to_binary(io_lib:format(" Saved Connections (~b)", [length(Conns)])),
    Body = case Conns of
        [] ->
            educkui_render_node:text(
                <<"  No connections saved. Press 'a' to add your first Redis connection.">>,
                dui_redis_theme:dim());
        _ ->
            list_widget(Conns, State)
    end,
    ErrorNodes = case dui_redis_state:connection_error(State) of
        undefined -> [];
        Error -> [educkui_render_node:text(<<"  Connection failed: ", Error/binary>>,
                                           dui_redis_theme:error())]
    end,
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(Header, dui_redis_theme:subtitle())
        | ErrorNodes ++ [Body, footer(connection_hints())]
    ]).

-spec list_widget([map()], #dui_state{}) -> #dui_node{}.
list_widget(Conns, State) ->
    Items = [conn_line(C) || C <- Conns],
    Total = length(Items),
    Selected = min(dui_redis_state:selected(State), max(0, Total - 1)),
    {Rows, _} = dui_redis_state:size(State),
    Visible = max(1, Rows - 7),
    {Offset, _} = educkui_widget_list:visible_range(Total, Selected, Visible),
    educkui_render_node:widget(educkui_widget_list, #{
        items => Items,
        selected => Selected,
        offset => Offset,
        style => educkui_style:new(),
        selected_style => dui_redis_theme:selected()
    }).

-spec conn_line(map()) -> binary().
conn_line(Conn) ->
    Name = to_bin(maps:get(name, Conn, <<>>)),
    Host = to_bin(maps:get(host, Conn, <<>>)),
    Port = maps:get(port, Conn, 6379),
    Cluster = maps:get(use_cluster, Conn, false),
    Tls = maps:get(use_tls, Conn, false),
    Db = case Cluster of
        true -> <<>>;
        false -> iolist_to_binary(io_lib:format("  db~b", [maps:get(db, Conn, 0)]))
    end,
    Badge = case Cluster of
        true -> <<"  [CLUSTER]">>;
        false -> <<>>
    end,
    TlsBadge = case Tls of
        true -> <<"  [TLS]">>;
        false -> <<>>
    end,
    iolist_to_binary(["  ", Name, "  ", Host, ":", integer_to_binary(Port),
                      Db, Badge, TlsBadge]).

%% -- connection form --------------------------------------------------------

-spec form_view(#dui_state{}) -> #dui_node{}.
form_view(State) ->
    Form = dui_redis_state:conn_form(State),
    Focus = dui_redis_form:focus(Form),
    Fields = dui_redis_form:fields(),
    FieldNodes = lists:flatmap(
        fun({Field, Index}) ->
            focused_field_nodes(Field, Index, Focus, Form)
        end,
        lists:zip(Fields, lists:seq(0, length(Fields) - 1))),
    ErrorNodes = case dui_redis_form:error(Form) of
        undefined -> [];
        Error -> [educkui_render_node:text(<<"  ", Error/binary>>, dui_redis_theme:error())]
    end,
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<"">>)
        | FieldNodes ++ ErrorNodes ++ [
            educkui_render_node:text(<<"">>),
            footer(<<" tab next   space toggle   enter save   Ctrl+T test   esc cancel">>)
        ]
    ]).

-spec focused_field_nodes(map(), non_neg_integer(), non_neg_integer(), map()) ->
    [#dui_node{}].
focused_field_nodes(Field, Index, Focus, Form) ->
    Label = maps:get(label, Field),
    Focused = Index =:= Focus,
    case maps:get(type, Field) of
        bool ->
            Checked = maps:get(maps:get(id, Field), dui_redis_form:values(Form), false),
            Box = case Checked of
                true -> <<"[x] ">>;
                false -> <<"[ ] ">>
            end,
            Prefix = case Focused of
                true -> <<"> ">>;
                false -> <<"  ">>
            end,
            Style = case Focused of
                true -> dui_redis_theme:info();
                false -> undefined
            end,
            [educkui_render_node:text(<<Prefix/binary, Box/binary, Label/binary>>, Style)];
        _ ->
            Value = dui_redis_form:value(Form, maps:get(id, Field)),
            Masked = maps:get(type, Field) =:= password,
            Prefix = case Focused of
                true -> <<"> ">>;
                false -> <<"  ">>
            end,
            Display = mask_value(Value, Masked),
            LabelNode = educkui_render_node:text(
                <<Prefix/binary, Label/binary, ":">>,
                dui_redis_theme:subtitle()),
            ValueNode = educkui_render_node:height(
                educkui_render_node:text(
                    <<"    ", Display/binary>>,
                    case Focused of
                        true -> dui_redis_theme:info();
                        false -> undefined
                    end), 1),
            [LabelNode, ValueNode]
    end.

-spec mask_value(binary(), boolean()) -> binary().
mask_value(Value, true) -> binary:copy(<<"*">>, string:length(Value));
mask_value(Value, false) -> Value.

%% -- test connection --------------------------------------------------------

-spec test_view(#dui_state{}) -> #dui_node{}.
test_view(State) ->
    Result = case dui_redis_state:test_result(State) of
        undefined -> <<"Testing...">>;
        R -> R
    end,
    Style = case Result of
        <<"Connected", _/binary>> -> dui_redis_theme:success();
        <<"Failed", _/binary>> -> dui_redis_theme:error();
        _ -> dui_redis_theme:dim()
    end,
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<"">>),
        educkui_render_node:text(<<"  Test Connection">>, dui_redis_theme:subtitle()),
        educkui_render_node:text(<<"">>),
        educkui_render_node:text(<<"  ", Result/binary>>, Style),
        educkui_render_node:text(<<"">>),
        footer(<<" esc/enter back">>)
    ]).

%% -- key detail / editor / prompt -------------------------------------------

-spec detail_view(#dui_state{}) -> #dui_node{}.
detail_view(State) ->
    KeyMap = case dui_redis_state:current_key(State) of
        undefined -> #{};
        K -> K
    end,
    Name = to_bin(maps:get(key, KeyMap, <<>>)),
    Type = current_type(State),
    Ttl = dui_redis_fmt:ttl_render(maps:get(ttl, KeyMap, -1)),
    Meta = <<"  type: ", (dui_redis_preview:type_label(Type))/binary,
             "   ttl: ", Ttl/binary>>,
    ValueLines = case dui_redis_state:current_value(State) of
        undefined -> [<<"loading...">>];
        Value -> dui_redis_preview:lines(Value, 5000)
    end,
    {Rows, _} = dui_redis_state:size(State),
    Visible = max(1, Rows - 8),
    Scroll = min(dui_redis_state:detail_scroll(State),
                 max(0, length(ValueLines) - 1)),
    Window = lists:sublist(ValueLines, Scroll + 1, Visible),
    LineNodes = [educkui_render_node:text(<<"  ", L/binary>>) || L <- Window],
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<" ", Name/binary>>, dui_redis_theme:title()),
        educkui_render_node:text(Meta, dui_redis_theme:subtitle()),
        educkui_render_node:text(<<>>)
        | LineNodes] ++
        [footer(<<" e edit   a add   x remove   t ttl   R rename   c copy   d delete   r refresh   esc back">>)
    ]).

-spec editor_view(#dui_state{}) -> #dui_node{}.
editor_view(State) ->
    Editor = dui_redis_state:editor(State),
    Lines = dui_redis_editor:lines(Editor),
    Row = dui_redis_editor:row(Editor),
    Col = dui_redis_editor:col(Editor),
    {Rows, _} = dui_redis_state:size(State),
    Visible = max(1, Rows - 6),
    Offset = max(0, Row - Visible + 1),
    Window = lists:sublist(Lines, Offset + 1, Visible),
    LineNodes = [editor_line_node(L, Offset + I, Row, Col)
                 || {L, I} <- lists:zip(Window, lists:seq(0, length(Window) - 1))],
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<" Edit value   Ctrl+S/F2 save   Esc cancel">>, dui_redis_theme:subtitle()),
        educkui_render_node:text(<<>>)
        | LineNodes ++ [footer(<<" arrows move   enter newline   Ctrl+S/F2 save   Esc cancel">>)]
    ]).

-spec editor_line_node(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    #dui_node{}.
editor_line_node(Line, Index, CursorRow, CursorCol) ->
    case Index =:= CursorRow of
        true ->
            educkui_render_node:widget(educkui_widget_text_view, #{
                lines => [[{<<"  ">>, undefined} | cursor_spans(Line, CursorCol)]]
            });
        false ->
            educkui_render_node:text(<<"  ", Line/binary>>)
    end.

-spec cursor_spans(binary(), non_neg_integer()) -> [{binary(), term()}].
cursor_spans(Line, Col) ->
    Before = string:slice(Line, 0, Col),
    At = string:slice(Line, Col, 1),
    After = string:slice(Line, Col + 1),
    AtChar = case At of
        <<>> -> <<" ">>;
        _ -> At
    end,
    [{Before, undefined},
     {AtChar, educkui_style:from([{reverse, true}])},
     {After, undefined}].

-spec prompt_view(#dui_state{}) -> #dui_node{}.
prompt_view(State) ->
    Prompt = dui_redis_state:prompt(State),
    Fields = dui_redis_prompt:fields(Prompt),
    Focus = dui_redis_prompt:focus(Prompt),
    FieldNodes = lists:flatmap(
        fun({Field, Index}) -> prompt_field_nodes(Field, Index, Focus, Prompt) end,
        lists:zip(Fields, lists:seq(0, length(Fields) - 1))),
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<>>),
        educkui_render_node:text(<<"  Tab next field   Enter submit   Esc cancel">>,
                                 dui_redis_theme:subtitle()),
        educkui_render_node:text(<<>>)
        | FieldNodes
    ]).

-spec prompt_field_nodes(dui_redis_prompt:field(), non_neg_integer(),
                         non_neg_integer(), dui_redis_prompt:prompt()) -> [#dui_node{}].
prompt_field_nodes({Id, Label, Masked}, Index, Focus, Prompt) ->
    Value = dui_redis_prompt:value(Prompt, Id),
    Display = case Masked of
        true -> binary:copy(<<"*">>, string:length(Value));
        false -> Value
    end,
    Prefix = case Index =:= Focus of
        true -> <<"> ">>;
        false -> <<"  ">>
    end,
    Style = case Index =:= Focus of
        true -> dui_redis_theme:info();
        false -> dui_redis_theme:subtitle()
    end,
    ValueStyle = case Index =:= Focus of
        true -> dui_redis_theme:info();
        false -> undefined
    end,
    [educkui_render_node:text(<<Prefix/binary, Label/binary, ":">>, Style),
     educkui_render_node:height(
        educkui_render_node:text(<<"    ", Display/binary>>, ValueStyle), 1)].

%% -- results / tree / result text -------------------------------------------

-spec results_view(#dui_state{}) -> #dui_node{}.
results_view(State) ->
    Title = dui_redis_state:results_title(State),
    Purpose = dui_redis_state:results_purpose(State),
    Results = dui_redis_state:results(State),
    Count = length(Results),
    Selected = min(dui_redis_state:selected_result(State), max(0, Count - 1)),
    {Rows, _} = dui_redis_state:size(State),
    Visible = max(1, Rows - 5),
    {Offset, _} = educkui_widget_list:visible_range(Count, Selected, Visible),
    Window = lists:sublist(Results, Offset + 1, Visible),
    Lines = [result_line(Purpose, R) || R <- Window],
    Header = iolist_to_binary(io_lib:format(" ~s  (~b)", [Title, Count])),
    Body = case Lines of
        [] ->
            educkui_render_node:height(
                educkui_render_node:text(<<"  (none)">>, dui_redis_theme:dim()), Visible);
        _ ->
            educkui_render_node:height(
                educkui_render_node:widget(educkui_widget_list, #{
                    items => Lines,
                    selected => Selected - Offset,
                    offset => 0,
                    style => educkui_style:new(),
                    selected_style => dui_redis_theme:selected()
                }), Visible)
    end,
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(Header, dui_redis_theme:subtitle()),
        Body,
        footer(<<" j/k nav   enter open   d remove   esc back">>)
    ]).

-spec result_line(atom() | undefined, map()) -> binary().
result_line(favorites, Entry) ->
    Label = to_bin(maps:get(label, Entry, <<>>)),
    Key = to_bin(maps:get(key, Entry, <<>>)),
    case Label of
        <<>> -> Key;
        _ -> <<Label/binary, "  ", Key/binary>>
    end;
result_line(recent, Entry) ->
    <<(to_bin(maps:get(key, Entry, <<>>)))/binary, "  [",
      (to_bin(maps:get(type, Entry, <<>>)))/binary, "]">>;
result_line(templates, Entry) ->
    <<(to_bin(maps:get(name, Entry, <<>>)))/binary, "  ",
      (to_bin(maps:get(key_pattern, Entry, <<>>)))/binary, "  ",
      (to_bin(maps:get(description, Entry, <<>>)))/binary>>;
result_line(history, Entry) ->
    Action = to_bin(maps:get(action, Entry, <<>>)),
    Key = to_bin(maps:get(key, Entry, <<>>)),
    <<Action/binary, "  ", Key/binary>>;
result_line(_Purpose, Entry) ->
    <<(to_bin(maps:get(key, Entry, <<>>)))/binary, "  [",
      (to_bin(maps:get(type, Entry, <<>>)))/binary, "]">>.

-spec tree_view(#dui_state{}) -> #dui_node{}.
tree_view(State) ->
    Flat = flattened_tree(State),
    Count = length(Flat),
    Selected = min(dui_redis_state:selected_tree(State), max(0, Count - 1)),
    Expanded = dui_redis_state:tree_expanded(State),
    {Rows, _} = dui_redis_state:size(State),
    Visible = max(1, Rows - 5),
    {Offset, _} = educkui_widget_list:visible_range(Count, Selected, Visible),
    Window = lists:sublist(Flat, Offset + 1, Visible),
    Lines = [tree_line(Depth, Node, Expanded) || {Depth, Node} <- Window],
    Body = case Lines of
        [] ->
            educkui_render_node:height(
                educkui_render_node:text(<<"  (no keys loaded)">>, dui_redis_theme:dim()), Visible);
        _ ->
            educkui_render_node:height(
                educkui_render_node:widget(educkui_widget_list, #{
                    items => Lines,
                    selected => Selected - Offset,
                    offset => 0,
                    style => educkui_style:new(),
                    selected_style => dui_redis_theme:selected()
                }), Visible)
    end,
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<" Tree">>, dui_redis_theme:subtitle()),
        Body,
        footer(<<" j/k nav   enter/right expand   left collapse   esc back">>)
    ]).

-spec tree_line(non_neg_integer(), map(), [binary()]) -> binary().
tree_line(Depth, Node, Expanded) ->
    Indent = binary:copy(<<"  ">>, Depth),
    Children = maps:get(children, Node, []),
    Path = maps:get(path, Node),
    Marker = case Children of
        [] -> <<"  ">>;
        _ ->
            case lists:member(Path, Expanded) of
                true -> <<"- ">>;
                false -> <<"+ ">>
            end
    end,
    Name = to_bin(maps:get(name, Node, <<>>)),
    case maps:get(is_key, Node, false) andalso Children =:= [] of
        true -> <<Indent/binary, Marker/binary, Name/binary>>;
        false -> <<Indent/binary, Marker/binary, Name/binary, "/">>
    end.

-spec result_text_view(#dui_state{}) -> #dui_node{}.
result_text_view(State) ->
    Text = case dui_redis_state:result_text(State) of
        undefined -> <<>>;
        T -> T
    end,
    Lines = binary:split(Text, <<"\n">>, [global]),
    {Rows, _} = dui_redis_state:size(State),
    Visible = max(1, Rows - 4),
    Window = lists:sublist(Lines, Visible),
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<" Result">>, dui_redis_theme:subtitle()),
        educkui_render_node:text(<<>>)
        | [educkui_render_node:text(<<"  ", L/binary>>) || L <- Window] ++
          [footer(<<" esc back">>)]
    ]).

%% -- confirm delete ---------------------------------------------------------

-spec confirm_view(#dui_state{}) -> #dui_node{}.
confirm_view(State) ->
    {Title, Content} = case dui_redis_state:confirm(State) of
        {delete_connection, Conn} ->
            Name = to_bin(maps:get(name, Conn, <<>>)),
            {<<"Confirm Delete">>, <<"Delete connection \"", Name/binary, "\"?  (y/n)">>};
        {delete_key, KeyMap} ->
            Key = to_bin(maps:get(key, KeyMap, <<>>)),
            {<<"Confirm Delete">>, <<"Delete key \"", Key/binary, "\"?  (y/n)">>};
        flush_db ->
            {<<"Confirm Flush">>, <<"Flush the current database?  (y/n)">>};
        _ ->
            {<<"Confirm">>, <<"(y/n)">>}
    end,
    educkui_render_node:widget(educkui_widget_dialog, #{
        title => Title,
        content => Content,
        buttons => [],
        width => 50,
        height => 6
    }).

%% -- keys -------------------------------------------------------------------

-spec keys_view(#dui_state{}) -> #dui_node{}.
keys_view(State) ->
    {_, Cols} = dui_redis_state:size(State),
    Body = case Cols >= 100 of
        true ->
            ListW = (Cols * 6) div 10,
            PreviewW = max(10, Cols - ListW - 1),
            educkui_render_node:stack(horizontal, [
                educkui_render_node:width(keys_panel(State, ListW), ListW),
                educkui_render_node:width(preview_panel(State), PreviewW)
            ]);
        false ->
            keys_panel(State, Cols)
    end,
    educkui_render_node:stack(vertical, [Body, footer(keys_hints(State))]).

-spec keys_panel(#dui_state{}, pos_integer()) -> #dui_node{}.
keys_panel(State, Width) ->
    Pattern = displayed_pattern(State),
    FilterNode = case dui_redis_state:filter_active(State) of
        true ->
            educkui_render_node:text(<<" Filter: ", Pattern/binary, "_">>, dui_redis_theme:info());
        false ->
            educkui_render_node:text(<<" Filter: ", Pattern/binary>>, dui_redis_theme:subtitle())
    end,
    {Rows, _} = dui_redis_state:size(State),
    Visible = max(1, Rows - 6),
    Keys = dui_redis_state:keys(State),
    Total = length(Keys),
    Selected = min(dui_redis_state:selected_key(State), max(0, Total - 1)),
    {Offset, _} = educkui_widget_list:visible_range(Total, Selected, Visible),
    Window = lists:sublist(Keys, Offset + 1, Visible),
    KeyW = max(10, Width - 26),
    RowsData = [[display_name(K), dui_redis_preview:type_label(maps:get(type, K, string)),
                 dui_redis_fmt:ttl_render(maps:get(ttl, K, -1))] || K <- Window],
    Table = case RowsData of
        [] ->
            educkui_render_node:height(
                educkui_render_node:text(<<"  No keys found.">>, dui_redis_theme:dim()),
                Visible);
        _ ->
            educkui_render_node:height(
                educkui_render_node:widget(educkui_widget_table, #{
                    header => [<<"Key">>, <<"Type">>, <<"TTL">>],
                    rows => RowsData,
                    widths => [KeyW, 11, 12],
                    selected => Selected - Offset,
                    style => educkui_style:new(),
                    selected_style => dui_redis_theme:selected(),
                    header_style => dui_redis_theme:subtitle()
                }), Visible)
    end,
    Count = iolist_to_binary(io_lib:format(" Keys ~b/~b", [Total, dui_redis_state:total_keys(State)])),
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(Count, dui_redis_theme:subtitle()),
        FilterNode,
        Table
    ]).

-spec preview_panel(#dui_state{}) -> #dui_node{}.
preview_panel(State) ->
    case dui_redis_state:preview_value(State) of
        undefined ->
            educkui_render_node:stack(vertical, [
                educkui_render_node:text(<<" Preview">>, dui_redis_theme:subtitle()),
                educkui_render_node:text(<<"  (select a key)">>, dui_redis_theme:dim())
            ]);
        Value ->
            Summary = dui_redis_preview:summary(Value),
            Lines = dui_redis_preview:lines(Value, 200),
            educkui_render_node:stack(vertical, [
                educkui_render_node:text(<<" Preview">>, dui_redis_theme:subtitle()),
                educkui_render_node:text(<<"  ", Summary/binary>>, dui_redis_theme:info()),
                educkui_render_node:text(<<>>)
                | [educkui_render_node:text(<<"  ", Line/binary>>) || Line <- Lines]
            ])
    end.

-spec switch_db_view(#dui_state{}) -> #dui_node{}.
switch_db_view(State) ->
    Edit = dui_redis_state:db_input(State),
    Value = case Edit of
        undefined -> <<>>;
        _ -> educkui_lineedit:value(Edit)
    end,
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<>>),
        educkui_render_node:text(<<"  Switch Database">>, dui_redis_theme:subtitle()),
        educkui_render_node:text(<<>>),
        educkui_render_node:text(<<"  db: ", Value/binary, "_">>, dui_redis_theme:info()),
        educkui_render_node:text(<<>>),
        footer(<<" enter switch   esc cancel">>)
    ]).

-spec displayed_pattern(#dui_state{}) -> binary().
displayed_pattern(State) ->
    case dui_redis_state:filter_active(State) of
        true ->
            case dui_redis_state:filter_edit(State) of
                undefined -> <<>>;
                Edit -> educkui_lineedit:value(Edit)
            end;
        false ->
            dui_redis_state:key_pattern(State)
    end.

-spec display_name(map()) -> binary().
display_name(Key) -> to_bin(maps:get(key, Key, <<>>)).

-spec keys_hints(#dui_state{}) -> binary().
keys_hints(State) ->
    Loading = case dui_redis_state:loading_keys(State) of
        true -> <<"  loading...">>;
        false -> <<>>
    end,
    More = case dui_redis_state:key_cursor(State) of
        0 -> <<>>;
        _ -> <<"  l more">>
    end,
    iolist_to_binary([" j/k nav   Enter view   / filter   s sort", More,
                      "   r refresh   D db   esc disconnect   q quit", Loading]).

%% -- shared -----------------------------------------------------------------

-spec help_view() -> #dui_node{}.
help_view() ->
    Lines = [
        <<"">>,
        <<"    ?        toggle this help">>,
        <<"    q        quit">>,
        <<"    Ctrl+C   quit">>,
        <<"    Esc      back / cancel">>,
        <<"">>,
        <<"  Connections">>,
        <<"    j/k      navigate">>,
        <<"    Enter    connect">>,
        <<"    a/n      add connection">>,
        <<"    e        edit connection">>,
        <<"    d        delete connection">>,
        <<"    r        reload from disk">>,
        <<"">>,
        <<"  Form">>,
        <<"    Tab      next field">>,
        <<"    Space    toggle checkbox">>,
        <<"    Enter    save">>,
        <<"    Ctrl+T   test connection">>,
        <<"    Esc      cancel">>
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
    Connected = case dui_redis_state:connected(State) of
        true -> <<"connected">>;
        false -> <<"disconnected">>
    end,
    iolist_to_binary(io_lib:format(
        " ~s   ~bx~b   ? help   q quit", [Connected, Cols, Rows])).

-spec footer(binary()) -> #dui_node{}.
footer(Text) ->
    educkui_render_node:height(
        educkui_render_node:text(Text, dui_redis_theme:dim()), 1).

-spec connection_hints() -> binary().
connection_hints() ->
    <<" j/k navigate   Enter connect   a add   e edit   d delete   r reload   q quit">>.

-spec error_text(term()) -> binary().
error_text(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

-spec to_bin(term()) -> binary().
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(undefined) -> <<>>;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
