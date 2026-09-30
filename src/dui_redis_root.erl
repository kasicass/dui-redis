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
event_to_msg(#dui_event{type = custom, key = message, content = {_Id, Msg}}, _State) ->
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
    S1 = dui_redis_state:incr_tick(State),
    S2 = expire_status(S1),
    {S2, tick_commands(S2)};
update({resize, W, H}, State) ->
    {dui_redis_state:set_size(State, H, W), []};
update({mouse_click, X, Y}, State) ->
    mouse_select(State, X, Y);
update({mouse_scroll, Dir, _X, _Y}, State) ->
    mouse_scroll(State, Dir);
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
update({server_info_loaded, {ok, Info}}, State) ->
    S1 = dui_redis_state:set_server_info(State, Info),
    {dui_redis_state:set_screen(S1, server_info), []};
update({server_info_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({slow_log_loaded, {ok, Entries}}, State) ->
    S1 = dui_redis_state:set_slow_log(State, Entries),
    {dui_redis_state:set_screen(S1, slow_log), []};
update({slow_log_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({clients_loaded, {ok, Clients}}, State) ->
    S1 = dui_redis_state:set_clients(State, Clients),
    {dui_redis_state:set_screen(S1, client_list), []};
update({clients_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({memory_stats_loaded, {ok, Stats}}, State) ->
    S1 = dui_redis_state:set_memory_stats(State, Stats),
    {dui_redis_state:set_screen(S1, memory_stats), []};
update({memory_stats_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({live_metrics_loaded, {ok, Metric}}, State) ->
    case dui_redis_state:metrics_active(State) of
        true ->
            S1 = dui_redis_state:push_metric(State, Metric),
            {dui_redis_state:set_screen(S1, live_metrics), []};
        false ->
            {State, []}
    end;
update({live_metrics_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({expiring_loaded, {ok, Keys}}, State) ->
    S1 = dui_redis_state:set_expiring(State, Keys),
    {dui_redis_state:set_screen(S1, expiring_keys), []};
update({expiring_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({channels_loaded, {ok, Channels}}, State) ->
    S1 = dui_redis_state:set_channels(State, Channels),
    {dui_redis_state:set_screen(S1, pubsub_channels), []};
update({channels_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({published, Channel, {ok, N}}, State) ->
    Msg = iolist_to_binary(io_lib:format("Published to ~s (~b receiver(s))", [Channel, N])),
    S1 = dui_redis_state:set_screen(State, keys),
    {dui_redis_state:set_status(S1, info, Msg), []};
update({published, _Channel, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({lua_result, {ok, Value}}, State) ->
    S1 = dui_redis_state:set_result_text(State, to_bin(Value)),
    {dui_redis_state:set_screen(S1, result_text), []};
update({lua_result, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({redis_config_loaded, {ok, Map}}, State) ->
    Params = lists:sort(maps:to_list(Map)),
    S1 = dui_redis_state:set_config_params(State, Params),
    {dui_redis_state:set_screen(S1, redis_config), []};
update({redis_config_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({config_set, Param, ok}, State) ->
    Msg = <<"Updated ", Param/binary>>,
    S1 = dui_redis_state:set_screen(State, redis_config),
    S2 = dui_redis_state:set_status(S1, info, Msg),
    {S2, [dui_redis_cmd:load_redis_config(State)]};
update({config_set, _Param, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({cluster_loaded, {ok, Nodes}}, State) ->
    S1 = dui_redis_state:set_cluster_nodes(State, Nodes),
    {dui_redis_state:set_screen(S1, cluster_info), []};
update({cluster_loaded, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({export_done, {ok, N}}, State) ->
    Msg = iolist_to_binary(io_lib:format("Exported ~b key(s)", [N])),
    {dui_redis_state:set_status(State, info, Msg), []};
update({export_done, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({import_done, {ok, N}}, State) ->
    Msg = iolist_to_binary(io_lib:format("Imported ~b key(s)", [N])),
    S1 = dui_redis_state:set_status(State, info, Msg),
    reload_keys(S1);
update({import_done, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({bulk_deleted, {ok, N}}, State) ->
    Msg = iolist_to_binary(io_lib:format("Deleted ~b key(s)", [N])),
    S1 = dui_redis_state:set_status(State, info, Msg),
    reload_keys(S1);
update({bulk_deleted, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({batch_ttl_done, {ok, N}}, State) ->
    Msg = iolist_to_binary(io_lib:format("Set TTL on ~b key(s)", [N])),
    S1 = dui_redis_state:set_status(State, info, Msg),
    reload_keys(S1);
update({batch_ttl_done, {error, Reason}}, State) ->
    {dui_redis_state:set_status(State, error, error_text(Reason)), []};
update({groups_loaded, {ok, Groups}}, State) ->
    S1 = dui_redis_state:set_groups(State, Groups),
    {dui_redis_state:set_screen(S1, groups), []};
update({groups_loaded, {error, Reason}}, State) ->
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
handle_escape(#dui_state{screen = live_metrics} = State) ->
    S1 = dui_redis_state:set_metrics_active(State, false),
    {dui_redis_state:set_screen(S1, keys), []};
handle_escape(#dui_state{screen = S} = State)
        when S =:= server_info; S =:= slow_log; S =:= client_list;
             S =:= memory_stats; S =:= expiring_keys; S =:= logs;
             S =:= pubsub_channels; S =:= redis_config; S =:= cluster_info;
             S =:= groups ->
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
screen_key(#dui_state{screen = S} = State, Key, Mods)
        when S =:= server_info; S =:= slow_log; S =:= client_list;
             S =:= memory_stats; S =:= live_metrics; S =:= expiring_keys;
             S =:= logs; S =:= pubsub_channels; S =:= redis_config;
             S =:= cluster_info; S =:= groups ->
    monitor_key(State, Key, Mods);
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
connections_key(State, <<"g">>, _Mods) ->
    start_groups(State);
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
keys_nav_key(State, home, _Mods) ->
    select_key(State, 0);
keys_nav_key(State, <<"g">>, Mods) ->
    case lists:member(ctrl, Mods) of
        true -> start_redis_config(State);
        false -> select_key(State, 0)
    end;
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
keys_nav_key(State, <<"l">>, Mods) ->
    case lists:member(ctrl, Mods) of
        true -> start_clients(State);
        false -> load_more_keys(State)
    end;
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
keys_nav_key(State, <<"i">>, _Mods) ->
    start_server_info(State);
keys_nav_key(State, <<"L">>, _Mods) ->
    start_slow_log(State);
keys_nav_key(State, <<"M">>, _Mods) ->
    start_memory_stats(State);
keys_nav_key(State, <<"m">>, _Mods) ->
    start_live_metrics(State);
keys_nav_key(State, <<"x">>, Mods) ->
    case lists:member(ctrl, Mods) of
        true -> start_expiring(State);
        false -> {State, []}
    end;
keys_nav_key(State, <<"O">>, _Mods) ->
    start_logs(State);
keys_nav_key(State, <<"p">>, _Mods) ->
    start_channels(State);
keys_nav_key(State, <<"E">>, _Mods) ->
    start_prompt(State, lua);
keys_nav_key(State, <<"e">>, _Mods) ->
    start_prompt(State, export);
keys_nav_key(State, <<"I">>, _Mods) ->
    start_prompt(State, import);
keys_nav_key(State, <<"B">>, _Mods) ->
    start_prompt(State, bulk_delete);
keys_nav_key(State, <<"T">>, _Mods) ->
    start_prompt(State, batch_ttl);
keys_nav_key(State, <<"C">>, _Mods) ->
    start_cluster(State);
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
        <<"y">> -> copy_current_key(State);
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

-spec start_prompt(#dui_state{}, term()) ->
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
start_prompt(State, {publish, Channel}) ->
    Prompt = dui_redis_prompt:new([{message, <<"Message">>, false}]),
    open_prompt(State, Prompt, {publish, Channel});
start_prompt(State, lua) ->
    Prompt = dui_redis_prompt:new([{script, <<"Lua script">>, false}]),
    open_prompt(State, Prompt, lua);
start_prompt(State, export) ->
    Prompt = dui_redis_prompt:new([{pattern, <<"Key pattern">>, false},
                                   {filename, <<"Export filename">>, false}]),
    open_prompt(State, Prompt, export);
start_prompt(State, import) ->
    Prompt = dui_redis_prompt:new([{filename, <<"Import filename">>, false}]),
    open_prompt(State, Prompt, import);
start_prompt(State, bulk_delete) ->
    Prompt = dui_redis_prompt:new([{pattern, <<"Pattern to delete (e.g. user:*)">>, false}]),
    open_prompt(State, Prompt, bulk_delete);
start_prompt(State, batch_ttl) ->
    Prompt = dui_redis_prompt:new([{pattern, <<"Key pattern">>, false},
                                   {ttl, <<"TTL seconds">>, false}]),
    open_prompt(State, Prompt, batch_ttl);
start_prompt(State, {config_edit, Param, Current}) ->
    Prompt = dui_redis_prompt:new([{value, <<"New value">>, false}], #{value => Current}),
    open_prompt(State, Prompt, {config_edit, Param, Current});
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
    {key_detail, [dui_redis_cmd:json_get_path(Key, maps:get(path, Values, <<>>))]};
prompt_action({publish, Channel}, Values) ->
    {keys, [dui_redis_cmd:publish(Channel, maps:get(message, Values, <<>>))]};
prompt_action(lua, Values) ->
    {keys, [dui_redis_cmd:eval_script(maps:get(script, Values, <<>>))]};
prompt_action(export, Values) ->
    Pattern = default_pattern(maps:get(pattern, Values, <<>>)),
    {keys, [dui_redis_cmd:export_keys(Pattern, maps:get(filename, Values, <<"export.json">>))]};
prompt_action(import, Values) ->
    {keys, [dui_redis_cmd:import_keys(maps:get(filename, Values, <<"export.json">>))]};
prompt_action(bulk_delete, Values) ->
    {keys, [dui_redis_cmd:bulk_delete(default_pattern(maps:get(pattern, Values, <<>>)))]};
prompt_action(batch_ttl, Values) ->
    Ttl = case parse_int(maps:get(ttl, Values, <<>>)) of
        {ok, N} -> N;
        error -> 0
    end,
    {keys, [dui_redis_cmd:batch_ttl(default_pattern(maps:get(pattern, Values, <<>>)), Ttl)]};
prompt_action({config_edit, Param, _Current}, Values) ->
    {redis_config, [dui_redis_cmd:set_config(Param, maps:get(value, Values, <<>>))]}.

-spec default_pattern(binary()) -> binary().
default_pattern(<<>>) -> <<"*">>;
default_pattern(P) -> P.

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

-spec copy_current_key(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
copy_current_key(State) ->
    case dui_redis_state:current_key(State) of
        undefined ->
            {State, []};
        KeyMap ->
            Key = to_bin(maps:get(key, KeyMap, <<>>)),
            _ = educkui_runtime:copy_to_clipboard(Key),
            {dui_redis_state:set_status(State, info, <<"Copied to clipboard">>), []}
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

%% -- monitoring (M5) --------------------------------------------------------

%% @doc Auto-expires transient info statuses so the colored default status
%% bar becomes visible again; errors persist until the user acts.
-spec expire_status(#dui_state{}) -> #dui_state{}.
expire_status(State) ->
    case dui_redis_state:status(State) of
        {info, _} ->
            Age = dui_redis_state:ticks(State) - dui_redis_state:status_tick(State),
            case Age >= 4 of
                true -> dui_redis_state:clear_status(State);
                false -> State
            end;
        _ ->
            State
    end.

-spec tick_commands(#dui_state{}) -> [educkui_command:command()].
tick_commands(State) ->
    Metrics = case dui_redis_state:metrics_active(State) of
        true -> [dui_redis_cmd:load_live_metrics(State)];
        false -> []
    end,
    Expiring = case dui_redis_state:screen(State) of
        expiring_keys -> [dui_redis_cmd:load_expiring(State, 300)];
        _ -> []
    end,
    Metrics ++ Expiring.

-spec start_server_info(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_server_info(State) ->
    {dui_redis_state:set_loading(State, true), [dui_redis_cmd:load_server_info(State)]}.

-spec start_slow_log(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_slow_log(State) ->
    {dui_redis_state:set_loading(State, true), [dui_redis_cmd:load_slow_log(State, 20)]}.

-spec start_clients(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_clients(State) ->
    {dui_redis_state:set_loading(State, true), [dui_redis_cmd:load_clients(State)]}.

-spec start_memory_stats(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_memory_stats(State) ->
    {dui_redis_state:set_loading(State, true), [dui_redis_cmd:load_memory_stats(State)]}.

-spec start_live_metrics(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_live_metrics(State) ->
    S1 = dui_redis_state:set_loading(State, true),
    S2 = dui_redis_state:set_metrics_active(S1, true),
    S3 = dui_redis_state:clear_metrics(S2),
    {S3, [dui_redis_cmd:load_live_metrics(State)]}.

-spec start_expiring(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_expiring(State) ->
    {dui_redis_state:set_loading(State, true), [dui_redis_cmd:load_expiring(State, 300)]}.

-spec start_logs(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_logs(State) ->
    Runtime = runtime(State),
    Text = format_logs(educkui_runtime:logs(Runtime)),
    S1 = dui_redis_state:set_result_text(State, Text),
    {dui_redis_state:set_screen(S1, logs), []}.

-spec start_channels(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_channels(State) ->
    {dui_redis_state:set_loading(State, true), [dui_redis_cmd:load_channels(State)]}.

-spec start_cluster(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_cluster(State) ->
    {dui_redis_state:set_loading(State, true), [dui_redis_cmd:load_cluster(State)]}.

-spec start_redis_config(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_redis_config(State) ->
    {dui_redis_state:set_loading(State, true), [dui_redis_cmd:load_redis_config(State)]}.

-spec start_groups(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
start_groups(State) ->
    {dui_redis_state:set_loading(State, true), [dui_redis_cmd:load_groups(State)]}.

-spec publish_selected(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
publish_selected(State) ->
    Channels = dui_redis_state:channels(State),
    case Channels of
        [] ->
            {State, []};
        _ ->
            Index = min(dui_redis_state:row_selected(State), length(Channels) - 1),
            start_prompt(State, {publish, lists:nth(Index + 1, Channels)})
    end.

-spec edit_selected_config(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
edit_selected_config(State) ->
    Params = dui_redis_state:config_params(State),
    case Params of
        [] ->
            {State, []};
        _ ->
            Index = min(dui_redis_state:row_selected(State), length(Params) - 1),
            {Param, Value} = lists:nth(Index + 1, Params),
            start_prompt(State, {config_edit, Param, Value})
    end.

-spec format_logs([map()]) -> binary().
format_logs(Logs) ->
    join_lines([format_log(E) || E <- Logs]).

-spec format_log(map()) -> binary().
format_log(Event) ->
    Level = to_bin(maps:get(level, Event, info)),
    Msg = to_bin_msg(maps:get(msg, Event, <<>>)),
    <<"[", Level/binary, "] ", Msg/binary>>.

-spec to_bin_msg(term()) -> binary().
to_bin_msg({string, S}) -> to_bin(S);
to_bin_msg({Format, Args}) when is_list(Format), is_list(Args) ->
    iolist_to_binary(io_lib:format(Format, Args));
to_bin_msg(Other) -> to_bin(Other).

-spec monitor_key(#dui_state{}, term(), [atom()]) ->
    {#dui_state{}, [educkui_command:command()]}.
monitor_key(State, Key, _Mods) ->
    Count = row_count(State),
    Current = dui_redis_state:row_selected(State),
    case Key of
        enter ->
            case dui_redis_state:screen(State) of
                pubsub_channels -> publish_selected(State);
                redis_config -> edit_selected_config(State);
                _ -> {State, []}
            end;
        K when K =:= <<"j">>; K =:= down ->
            {dui_redis_state:set_row_selected(State, min(max(0, Count - 1), Current + 1)), []};
        K when K =:= <<"k">>; K =:= up ->
            {dui_redis_state:set_row_selected(State, max(0, Current - 1)), []};
        K when K =:= home; K =:= <<"g">> ->
            {dui_redis_state:set_row_selected(State, 0), []};
        K when K =:= 'end'; K =:= <<"G">> ->
            {dui_redis_state:set_row_selected(State, max(0, Count - 1)), []};
        <<"r">> -> reload_monitor(State);
        _ -> {State, []}
    end.

-spec reload_monitor(#dui_state{}) -> {#dui_state{}, [educkui_command:command()]}.
reload_monitor(State) ->
    case dui_redis_state:screen(State) of
        server_info -> {State, [dui_redis_cmd:load_server_info(State)]};
        slow_log -> {State, [dui_redis_cmd:load_slow_log(State, 20)]};
        client_list -> {State, [dui_redis_cmd:load_clients(State)]};
        memory_stats -> {State, [dui_redis_cmd:load_memory_stats(State)]};
        live_metrics -> {State, [dui_redis_cmd:load_live_metrics(State)]};
        expiring_keys -> {State, [dui_redis_cmd:load_expiring(State, 300)]};
        pubsub_channels -> {State, [dui_redis_cmd:load_channels(State)]};
        redis_config -> {State, [dui_redis_cmd:load_redis_config(State)]};
        cluster_info -> {State, [dui_redis_cmd:load_cluster(State)]};
        groups -> {State, [dui_redis_cmd:load_groups(State)]};
        logs -> start_logs(State);
        _ -> {State, []}
    end.

-spec row_count(#dui_state{}) -> non_neg_integer().
row_count(State) ->
    case dui_redis_state:screen(State) of
        server_info -> 12;
        slow_log -> length(dui_redis_state:slow_log(State));
        client_list -> length(dui_redis_state:clients(State));
        memory_stats ->
            case dui_redis_state:memory_stats(State) of
                undefined -> 0;
                Stats -> 6 + length(maps:get(top_keys, Stats, []))
            end;
        expiring_keys -> length(dui_redis_state:expiring(State));
        pubsub_channels -> length(dui_redis_state:channels(State));
        redis_config -> length(dui_redis_state:config_params(State));
        cluster_info -> length(dui_redis_state:cluster_nodes(State));
        groups -> length(dui_redis_state:groups(State));
        _ -> 0
    end.

-spec runtime(#dui_state{}) -> pid() | undefined.
runtime(#dui_state{runtime = P}) -> P.

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
    educkui_render_node:overlay([
        educkui_render_node:component(dui_mouse_layer, dui_redis_mouse),
        educkui_render_node:stack(vertical, [
            title_bar(State),
            body(State),
            status_bar(State)
        ])
    ]).

-spec title_bar(#dui_state{}) -> #dui_node{}.
title_bar(State) ->
    Version = list_to_binary(?DUI_REDIS_VERSION),
    Info = case dui_redis_state:current_conn(State) of
        undefined -> screen_title(State);
        Conn -> dui_redis_fmt:connection_label(Conn)
    end,
    Text = <<" dui-redis ", Version/binary, "  |  ", Info/binary>>,
    Base = educkui_render_node:height(
        educkui_render_node:text(Text, dui_redis_theme:title()), 1),
    case loading_active(State) of
        true ->
            Spinner = educkui_render_node:width(
                educkui_render_node:widget(educkui_widget_spinner, #{
                    frame => dui_redis_state:ticks(State),
                    style => dui_redis_theme:info(),
                    suffix => <<" loading">>
                }), 12),
            educkui_render_node:height(
                educkui_render_node:stack(horizontal, [Base, Spinner]), 1);
        false ->
            Base
    end.

-spec loading_active(#dui_state{}) -> boolean().
loading_active(State) ->
    dui_redis_state:loading(State) orelse dui_redis_state:loading_keys(State).

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
    educkui_render_node:height(
        educkui_render_node:overlay([
            connections_view(State),
            confirm_view(State)
        ]), auto);
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
screen_view(#dui_state{screen = S} = State)
        when S =:= server_info; S =:= slow_log; S =:= client_list;
             S =:= memory_stats; S =:= live_metrics; S =:= expiring_keys;
             S =:= logs; S =:= pubsub_channels; S =:= redis_config;
             S =:= cluster_info; S =:= groups ->
    monitor_view(State);
screen_view(_State) ->
    educkui_render_node:empty().

%% -- centered modal ---------------------------------------------------------

%% @doc Renders a centered, bordered modal box with a title and content lines.
-spec modal(#dui_state{}, binary(), [#dui_node{}], pos_integer()) -> #dui_node{}.
modal(State, Title, Content, Width0) ->
    {Rows, Cols} = dui_redis_state:size(State),
    Width = min(Width0, max(20, Cols - 2)),
    NeededH = length(Content) + 3,
    MaxH = max(3, Rows - 4),
    Height = min(NeededH, MaxH),
    Lines = lists:sublist(Content, 1, max(0, Height - 3)),
    TitleNode = educkui_render_node:text(
        <<" ", Title/binary>>, dui_redis_theme:title()),
    Inner = educkui_render_node:stack(vertical, [TitleNode | Lines]),
    Box = educkui_render_node:widget(educkui_widget_block, #{
        border => true,
        border_style => dui_redis_theme:border()
    }),
    Border = educkui_render_node:width(
        educkui_render_node:height(Box, Height), Width),
    ContentBox = educkui_render_node:box(
        [educkui_render_node:at(2, 1, Inner)],
        [{width, Width}, {height, Height}]),
    educkui_render_node:height(
        educkui_render_node:overlay([center(Border), center(ContentBox)]), auto).

%% @doc Centers a fixed-size node both horizontally and vertically.
-spec center(#dui_node{}) -> #dui_node{}.
center(Node) ->
    Horizontal = educkui_render_node:stack(horizontal, [Node], [{align, center}]),
    educkui_render_node:stack(vertical, [Horizontal], [{align, center}]).

%% @doc Renders a bordered panel with a title and content lines, filling the
%% given width and height. Unlike `modal/4' it is not centered.
-spec panel(binary(), [#dui_node{}], pos_integer(), pos_integer()) -> #dui_node{}.
panel(Title, Content, Width, Height) ->
    TitleNode = educkui_render_node:text(
        <<" ", Title/binary>>, dui_redis_theme:title()),
    Inner = educkui_render_node:stack(vertical, [TitleNode | Content]),
    Box = educkui_render_node:widget(educkui_widget_block, #{
        border => true,
        border_style => dui_redis_theme:border()
    }),
    Border = educkui_render_node:width(
        educkui_render_node:height(Box, Height), Width),
    ContentBox = educkui_render_node:width(
        educkui_render_node:height(
            educkui_render_node:at(2, 1, Inner), Height), Width),
    educkui_render_node:width(
        educkui_render_node:height(
            educkui_render_node:overlay([Border, ContentBox]), Height), Width).

%% @doc A unified screen header: title plus a dim horizontal rule.
-spec screen_header(binary()) -> #dui_node{}.
screen_header(Title) ->
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<" ", Title/binary>>, dui_redis_theme:title()),
        educkui_render_node:text(
            binary:copy(<<226, 148, 128>>, 200), dui_redis_theme:dim())
    ]).

%% @doc A gauge row sized so its trailing percentage label stays inside the
%% available width (the gauge widget draws the label one cell past the bar).
-spec gauge_row(number(), pos_integer(), #dui_style{}) -> #dui_node{}.
gauge_row(Value, Width, FillStyle) ->
    BarW = max(10, Width - 6),
    Gauge = educkui_render_node:width(
        educkui_render_node:height(
            educkui_render_node:widget(educkui_widget_gauge, #{
                value => Value,
                style => dui_redis_theme:dim(),
                fill_style => FillStyle
            }), 1),
        BarW),
    educkui_render_node:stack(horizontal, [Gauge]).

%% -- mouse hit testing ------------------------------------------------------

%% @doc Selects the list row under a mouse click, per screen.
-spec mouse_select(#dui_state{}, integer(), integer()) ->
    {#dui_state{}, [educkui_command:command()]}.
mouse_select(#dui_state{show_help = true} = State, _X, _Y) ->
    {State, []};
mouse_select(#dui_state{screen = connections} = State, _X, Y) ->
    Top = 10 + connection_error_count(State),
    case list_index(Y, Top, connections_visible(State),
                    length(dui_redis_state:connections(State)),
                    dui_redis_state:selected(State)) of
        undefined -> {State, []};
        I -> {dui_redis_state:set_selected(State, I), []}
    end;
mouse_select(#dui_state{screen = keys} = State, X, Y) ->
    {_, Cols} = dui_redis_state:size(State),
    ListW = case Cols >= 100 of
        true -> (Cols * 6) div 10;
        false -> Cols
    end,
    case X < ListW of
        false ->
            {State, []};
        true ->
            case list_index(Y, 7, keys_visible(State),
                            length(dui_redis_state:keys(State)),
                            dui_redis_state:selected_key(State)) of
                undefined -> {State, []};
                I -> select_key(State, I)
            end
    end;
mouse_select(#dui_state{screen = results} = State, _X, Y) ->
    case list_index(Y, 3, results_visible(State),
                    length(dui_redis_state:results(State)),
                    dui_redis_state:selected_result(State)) of
        undefined -> {State, []};
        I -> {dui_redis_state:set_selected_result(State, I), []}
    end;
mouse_select(#dui_state{screen = tree} = State, _X, Y) ->
    case list_index(Y, 3, results_visible(State),
                    length(flattened_tree(State)),
                    dui_redis_state:selected_tree(State)) of
        undefined -> {State, []};
        I -> {dui_redis_state:set_selected_tree(State, I), []}
    end;
mouse_select(#dui_state{screen = S} = State, _X, Y)
        when S =:= slow_log; S =:= client_list; S =:= expiring_keys;
             S =:= pubsub_channels; S =:= redis_config; S =:= cluster_info;
             S =:= groups ->
    case list_index(Y, 4, monitor_visible(State), monitor_row_count(State),
                    dui_redis_state:row_selected(State)) of
        undefined -> {State, []};
        I -> {dui_redis_state:set_row_selected(State, I), []}
    end;
mouse_select(State, _X, _Y) ->
    {State, []}.

%% @doc Scrolls the active list with the mouse wheel.
-spec mouse_scroll(#dui_state{}, up | down) ->
    {#dui_state{}, [educkui_command:command()]}.
mouse_scroll(#dui_state{show_help = true} = State, _Dir) ->
    {State, []};
mouse_scroll(State, up) -> scroll_select(State, -3);
mouse_scroll(State, down) -> scroll_select(State, 3).

-spec scroll_select(#dui_state{}, integer()) ->
    {#dui_state{}, [educkui_command:command()]}.
scroll_select(#dui_state{screen = keys} = State, Delta) ->
    move_key(State, Delta);
scroll_select(#dui_state{screen = connections} = State, Delta) ->
    {move_selected(State, Delta), []};
scroll_select(#dui_state{screen = results} = State, Delta) ->
    Count = length(dui_redis_state:results(State)),
    {dui_redis_state:set_selected_result(State,
        clamp_index(dui_redis_state:selected_result(State) + Delta, Count)), []};
scroll_select(#dui_state{screen = tree} = State, Delta) ->
    Count = length(flattened_tree(State)),
    {dui_redis_state:set_selected_tree(State,
        clamp_index(dui_redis_state:selected_tree(State) + Delta, Count)), []};
scroll_select(#dui_state{screen = S} = State, Delta)
        when S =:= slow_log; S =:= client_list; S =:= expiring_keys;
             S =:= pubsub_channels; S =:= redis_config; S =:= cluster_info;
             S =:= groups ->
    Count = monitor_row_count(State),
    {dui_redis_state:set_row_selected(State,
        clamp_index(dui_redis_state:row_selected(State) + Delta, Count)), []};
scroll_select(State, _Delta) ->
    {State, []}.

%% @doc Maps a screen row to a list index, accounting for the scroll offset.
-spec list_index(integer(), pos_integer(), pos_integer(), non_neg_integer(),
                 non_neg_integer()) -> non_neg_integer() | undefined.
list_index(Y, Top, Visible, Total, Selected) ->
    {Offset, _} = educkui_widget_list:visible_range(Total, Selected, Visible),
    Row = Y - Top,
    Index = Row + Offset,
    case Row >= 0 andalso Row < Visible andalso Index >= 0 andalso Index < Total of
        true -> Index;
        false -> undefined
    end.

-spec clamp_index(integer(), non_neg_integer()) -> non_neg_integer().
clamp_index(_I, 0) -> 0;
clamp_index(I, Count) -> max(0, min(Count - 1, I)).

-spec connection_error_count(#dui_state{}) -> non_neg_integer().
connection_error_count(State) ->
    case dui_redis_state:connection_error(State) of
        undefined -> 0;
        _ -> 1
    end.

-spec connections_visible(#dui_state{}) -> pos_integer().
connections_visible(State) ->
    {Rows, _} = dui_redis_state:size(State),
    max(1, Rows - 12 - connection_error_count(State)).

-spec keys_visible(#dui_state{}) -> pos_integer().
keys_visible(State) ->
    {Rows, _} = dui_redis_state:size(State),
    max(1, Rows - 9).

-spec results_visible(#dui_state{}) -> pos_integer().
results_visible(State) ->
    {Rows, _} = dui_redis_state:size(State),
    max(1, Rows - 6).

%% @doc Visible rows for `lines_view' screens (all carry a column header).
-spec monitor_visible(#dui_state{}) -> pos_integer().
monitor_visible(State) ->
    {Rows, _} = dui_redis_state:size(State),
    max(1, Rows - 7).

-spec monitor_row_count(#dui_state{}) -> non_neg_integer().
monitor_row_count(State) ->
    case dui_redis_state:screen(State) of
        slow_log -> length(dui_redis_state:slow_log(State));
        client_list -> length(dui_redis_state:clients(State));
        expiring_keys -> length(dui_redis_state:expiring(State));
        pubsub_channels -> length(dui_redis_state:channels(State));
        redis_config -> length(dui_redis_state:config_params(State));
        cluster_info -> length(dui_redis_state:cluster_nodes(State));
        groups -> length(dui_redis_state:groups(State));
        _ -> 0
    end.

%% -- connections ------------------------------------------------------------

-spec connections_view(#dui_state{}) -> #dui_node{}.
connections_view(State) ->
    Conns = dui_redis_state:connections(State),
    Header = iolist_to_binary(io_lib:format("Saved Connections (~b)", [length(Conns)])),
    Visible = connections_visible(State),
    Body = case Conns of
        [] ->
            educkui_render_node:text(
                <<"  No connections saved. Press 'a' to add your first Redis connection.">>,
                dui_redis_theme:dim());
        _ ->
            list_widget(Conns, State, Visible)
    end,
    ErrorNodes = case dui_redis_state:connection_error(State) of
        undefined -> [];
        Error -> [educkui_render_node:text(<<"  Connection failed: ", Error/binary>>,
                                           dui_redis_theme:error())]
    end,
    LogoNodes = [educkui_render_node:text(L, dui_redis_theme:logo())
                 || L <- logo_lines()],
    StatsNode = educkui_render_node:widget(educkui_widget_text_view,
        #{lines => [stats_spans(State, length(Conns))]}),
    educkui_render_node:stack(vertical,
        LogoNodes ++
        [educkui_render_node:text(<<>>), StatsNode, educkui_render_node:text(<<>>),
         educkui_render_node:text(Header, dui_redis_theme:title())]
        ++ ErrorNodes ++ [Body, footer(connection_hints())]).

-spec logo_lines() -> [binary()].
logo_lines() ->
    [<<"  ____  _____ ____ ___ ____">>,
     <<" |  _ \\| ____|  _ \\_ _/ ___|">>,
     <<" | |_) |  _| | | | | |\\___ \\">>,
     <<" |  _ <| |___| |_| | | ___) |">>,
     <<" |_| \\_\\_____|____/___|____/">>].

-spec stats_spans(#dui_state{}, non_neg_integer()) -> [{binary(), term()}].
stats_spans(State, Count) ->
    Db = case dui_redis_state:current_conn(State) of
        undefined -> 0;
        Conn -> maps:get(db, Conn, 0)
    end,
    Status = case dui_redis_state:connected(State) of
        true -> {<<"connected">>, dui_redis_theme:success()};
        false -> {<<"disconnected">>, dui_redis_theme:dim()}
    end,
    [{<<"  Connections: ">>, dui_redis_theme:dim()},
     {integer_to_binary(Count), dui_redis_theme:title()},
     {<<" saved">>, dui_redis_theme:dim()},
     {<<"    DB: ">>, dui_redis_theme:dim()},
     {integer_to_binary(Db), dui_redis_theme:title()},
     {<<"    Status: ">>, dui_redis_theme:dim()},
     Status].

-spec list_widget([map()], #dui_state{}, pos_integer()) -> #dui_node{}.
list_widget(Conns, State, Visible0) ->
    Total = length(Conns),
    Selected = min(dui_redis_state:selected(State), max(0, Total - 1)),
    Visible = max(1, Visible0),
    {Offset, _} = educkui_widget_list:visible_range(Total, Selected, Visible),
    Window = lists:sublist(Conns, Offset + 1, Visible),
    Lines = [conn_spans(C, Offset + I =:= Selected)
             || {C, I} <- lists:zip(Window, lists:seq(0, length(Window) - 1))],
    educkui_render_node:height(
        educkui_render_node:widget(educkui_widget_text_view, #{lines => Lines}), Visible).

-spec conn_spans(map(), boolean()) -> [{binary(), term()}].
conn_spans(Conn, Selected) ->
    Name = to_bin(maps:get(name, Conn, <<>>)),
    Host = to_bin(maps:get(host, Conn, <<>>)),
    Port = integer_to_binary(maps:get(port, Conn, 6379)),
    Cluster = maps:get(use_cluster, Conn, false),
    Tls = maps:get(use_tls, Conn, false),
    Db = case Cluster of
        true -> <<>>;
        false -> <<"  db", (integer_to_binary(maps:get(db, Conn, 0)))/binary>>
    end,
    Badges = iolist_to_binary([
        case Cluster of true -> <<"  [CLUSTER]">>; false -> <<>> end,
        case Tls of true -> <<"  [TLS]">>; false -> <<>> end
    ]),
    Marker = case Selected of
        true -> <<226, 151, 143, 32>>;   %% U+25CF filled circle
        false -> <<226, 151, 139, 32>>   %% U+25CB hollow circle
    end,
    NameStyle = case Selected of
        true -> dui_redis_theme:selected();
        false -> dui_redis_theme:title()
    end,
    HostStyle = case Selected of
        true -> dui_redis_theme:selected();
        false -> dui_redis_theme:dim()
    end,
    [{Marker, NameStyle},
     {Name, NameStyle},
     {<<"  ", Host/binary, ":", Port/binary>>, HostStyle},
     {Db, dui_redis_theme:meta_dim()},
     {Badges, dui_redis_theme:success()}].

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
    Content = [educkui_render_node:text(<<"">>) | FieldNodes]
        ++ ErrorNodes
        ++ [educkui_render_node:text(<<"">>),
            footer(<<" tab next   space toggle   enter save   Ctrl+T test   esc cancel">>)],
    modal(State, screen_title(State), Content, 72).

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
    Content = [
        educkui_render_node:text(<<"">>),
        educkui_render_node:text(<<"  ", Result/binary>>, Style),
        educkui_render_node:text(<<"">>),
        footer(<<" esc/enter back">>)
    ],
    modal(State, <<"Test Connection">>, Content, 52).

%% -- key detail / editor / prompt -------------------------------------------

-spec detail_view(#dui_state{}) -> #dui_node{}.
detail_view(State) ->
    KeyMap = case dui_redis_state:current_key(State) of
        undefined -> #{};
        K -> K
    end,
    Name = to_bin(maps:get(key, KeyMap, <<>>)),
    Type = current_type(State),
    TtlSeconds = maps:get(ttl, KeyMap, -1),
    Ttl = dui_redis_fmt:ttl_render(TtlSeconds),
    {Rows, Cols} = dui_redis_state:size(State),
    PanelH = max(3, Rows - 6),
    Visible = max(1, PanelH - 3),
    LineNodes = value_line_nodes(dui_redis_state:current_value(State), Visible, State),
    MetaNode = educkui_render_node:widget(educkui_widget_text_view, #{lines => [[
        {<<"  type: ">>, dui_redis_theme:dim()},
        {dui_redis_preview:type_label(Type), dui_redis_theme:type_style_bold(Type)},
        {<<"   ttl: ">>, dui_redis_theme:dim()},
        {Ttl, dui_redis_theme:ttl_style(TtlSeconds)}
    ]]}),
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<" ", Name/binary>>, dui_redis_theme:title()),
        MetaNode,
        panel(<<"Value">>, LineNodes, Cols, PanelH),
        footer(<<" e edit   a add   x remove   t ttl   R rename   c copy   d delete   r refresh   esc back">>)
    ]).

%% @doc Builds the value body nodes, highlighting JSON values.
-spec value_line_nodes(map() | undefined, pos_integer(), #dui_state{}) -> [#dui_node{}].
value_line_nodes(undefined, _Visible, _State) ->
    [educkui_render_node:text(<<"  loading...">>, dui_redis_theme:dim())];
value_line_nodes(Value, Visible, State) ->
    case json_text(Value) of
        {true, Text} ->
            json_line_nodes(Text, Visible, State);
        false ->
            ValueLines = dui_redis_preview:lines(Value, 5000),
            Scroll = min(dui_redis_state:detail_scroll(State),
                         max(0, length(ValueLines) - 1)),
            Window = lists:sublist(ValueLines, Scroll + 1, Visible),
            [educkui_render_node:text(<<"  ", L/binary>>) || L <- Window]
    end.

-spec json_text(map()) -> {true, binary()} | false.
json_text(#{type := json, text := Text}) -> {true, Text};
json_text(#{json := true, text := Text}) -> {true, Text};
json_text(_) -> false.

-spec json_line_nodes(binary(), pos_integer(), #dui_state{}) -> [#dui_node{}].
json_line_nodes(Text, Visible, State) ->
    JLines = dui_redis_json:lines(Text),
    Scroll = min(dui_redis_state:detail_scroll(State), max(0, length(JLines) - 1)),
    Window = lists:sublist(JLines, Scroll + 1, Visible),
    [educkui_render_node:widget(educkui_widget_text_view, #{
         lines => [[{<<"  ">>, undefined} | Spans]]
     }) || Spans <- Window].

-spec editor_view(#dui_state{}) -> #dui_node{}.
editor_view(State) ->
    Editor = dui_redis_state:editor(State),
    Lines = dui_redis_editor:lines(Editor),
    Row = dui_redis_editor:row(Editor),
    Col = dui_redis_editor:col(Editor),
    {Rows, Cols} = dui_redis_state:size(State),
    PanelH = max(3, Rows - 4),
    Visible = max(1, PanelH - 3),
    Offset = max(0, Row - Visible + 1),
    Window = lists:sublist(Lines, Offset + 1, Visible),
    LineNodes = [editor_line_node(L, Offset + I, Row, Col)
                 || {L, I} <- lists:zip(Window, lists:seq(0, length(Window) - 1))],
    educkui_render_node:stack(vertical, [
        panel(<<"Edit value">>, LineNodes, Cols, PanelH),
        footer(<<" arrows move   enter newline   Ctrl+S/F2 save   Esc cancel">>)
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
    Title = prompt_title(dui_redis_state:prompt_purpose(State)),
    Content = [
        educkui_render_node:text(
            <<" Tab next field   Enter submit   Esc cancel">>, dui_redis_theme:subtitle()),
        educkui_render_node:text(<<>>)
        | FieldNodes
    ],
    modal(State, Title, Content, 72).

%% @doc Derives a human-readable title from the prompt purpose.
-spec prompt_title(term()) -> binary().
prompt_title({rename, _}) -> <<"Rename Key">>;
prompt_title({copy, _}) -> <<"Copy Key">>;
prompt_title({ttl, _}) -> <<"Set TTL">>;
prompt_title({regex, _}) -> <<"Regex Search">>;
prompt_title({fuzzy, _}) -> <<"Fuzzy Search">>;
prompt_title({search_value, _}) -> <<"Search by Value">>;
prompt_title({compare, _}) -> <<"Compare Keys">>;
prompt_title({json_path, _}) -> <<"JSONPath">>;
prompt_title({publish, _}) -> <<"Publish Message">>;
prompt_title(lua) -> <<"Lua Script">>;
prompt_title(export) -> <<"Export Keys">>;
prompt_title(import) -> <<"Import Keys">>;
prompt_title(bulk_delete) -> <<"Bulk Delete">>;
prompt_title(batch_ttl) -> <<"Batch TTL">>;
prompt_title({collection_add, _, _}) -> <<"Add Member">>;
prompt_title({collection_remove, _, _}) -> <<"Remove Member">>;
prompt_title({config_edit, _, _}) -> <<"Edit Config">>;
prompt_title(_) -> <<"Input">>.

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
    Visible = results_visible(State),
    {Offset, _} = educkui_widget_list:visible_range(Count, Selected, Visible),
    Window = lists:sublist(Results, Offset + 1, Visible),
    Lines = [result_line(Purpose, R) || R <- Window],
    Header = iolist_to_binary(io_lib:format("~s  (~b)", [Title, Count])),
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
        screen_header(Header),
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
    Visible = results_visible(State),
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
        screen_header(<<"Tree">>),
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
    Visible = max(1, Rows - 6),
    Window = lists:sublist(Lines, Visible),
    educkui_render_node:stack(vertical, [
        screen_header(<<"Result">>)
        | [educkui_render_node:text(<<"  ", L/binary>>) || L <- Window] ++
          [footer(<<" esc back">>)]
    ]).

%% -- monitoring views (M5) --------------------------------------------------

-spec monitor_view(#dui_state{}) -> #dui_node{}.
monitor_view(State) ->
    case dui_redis_state:screen(State) of
        server_info -> info_view(State);
        slow_log -> slow_log_view(State);
        client_list -> clients_view(State);
        memory_stats -> memory_view(State);
        live_metrics -> metrics_view(State);
        expiring_keys -> expiring_view(State);
        pubsub_channels -> channels_view(State);
        redis_config -> redis_config_view(State);
        cluster_info -> cluster_view(State);
        groups -> groups_view(State);
        logs -> result_text_view(State);
        _ -> educkui_render_node:empty()
    end.

-spec lines_view(#dui_state{}, binary(), binary(), [binary()], binary()) -> #dui_node{}.
lines_view(State, Title, Header, Lines, Hints) ->
    Count = length(Lines),
    Selected = min(dui_redis_state:row_selected(State), max(0, Count - 1)),
    {Rows, _} = dui_redis_state:size(State),
    HeaderLines = case Header of
        <<>> -> 0;
        _ -> 1
    end,
    Visible = max(1, Rows - 6 - HeaderLines),
    {Offset, _} = educkui_widget_list:visible_range(Count, Selected, Visible),
    Window = lists:sublist(Lines, Offset + 1, Visible),
    Body = case Window of
        [] ->
            educkui_render_node:height(
                educkui_render_node:text(<<"  (none)">>, dui_redis_theme:dim()), Visible);
        _ ->
            educkui_render_node:height(
                educkui_render_node:widget(educkui_widget_list, #{
                    items => Window,
                    selected => Selected - Offset,
                    offset => 0,
                    style => educkui_style:new(),
                    selected_style => dui_redis_theme:selected()
                }), Visible)
    end,
    HeaderNodes = case Header of
        <<>> -> [];
        _ -> [educkui_render_node:text(<<"  ", Header/binary>>, dui_redis_theme:subtitle())]
    end,
    educkui_render_node:stack(vertical,
        [screen_header(Title)] ++ HeaderNodes ++ [Body, footer(Hints)]).

-spec info_view(#dui_state{}) -> #dui_node{}.
info_view(State) ->
    Info = case dui_redis_state:server_info(State) of
        undefined -> #{};
        I -> I
    end,
    {Rows, Cols} = dui_redis_state:size(State),
    Height = max(3, Rows - 4),
    Lines = [
        kv(<<"version">>, maps:get(version, Info, <<>>)),
        kv(<<"mode">>, maps:get(mode, Info, <<>>)),
        kv(<<"os">>, maps:get(os, Info, <<>>)),
        kv(<<"clients">>, maps:get(clients, Info, <<>>)),
        kv(<<"db keys">>, maps:get(total_keys, Info, <<>>)),
        kv(<<"used memory">>, maps:get(used_memory, Info, <<>>)),
        kv(<<"peak memory">>, maps:get(peak_memory, Info, <<>>)),
        kv(<<"frag ratio">>, maps:get(frag_ratio, Info, <<>>)),
        kv(<<"total commands">>, maps:get(total_commands, Info, <<>>)),
        kv(<<"uptime">>, dui_redis_fmt:duration(maps:get(uptime_seconds, Info, 0))),
        kv(<<"cluster">>, dui_redis_fmt:bool(maps:get(cluster, Info, false))),
        kv(<<"aof">>, dui_redis_fmt:bool(maps:get(aof, Info, false)))
    ],
    Content = [educkui_render_node:text(L) || L <- Lines],
    educkui_render_node:stack(vertical, [
        panel(<<"Server Info">>, Content, Cols, Height),
        footer(<<" r refresh   esc back">>)
    ]).

-spec slow_log_view(#dui_state{}) -> #dui_node{}.
slow_log_view(State) ->
    Lines = [slow_line(E) || E <- dui_redis_state:slow_log(State)],
    lines_view(State, <<"Slow Log">>, <<"ID       ms     command">>, Lines,
               <<" j/k nav   r refresh   esc back">>).

-spec slow_line(map()) -> binary().
slow_line(E) ->
    iolist_to_binary(io_lib:format("~-8b ~-6b ~s",
        [maps:get(id, E, 0), maps:get(duration, E, 0), to_bin(maps:get(command, E, <<>>))])).

-spec clients_view(#dui_state{}) -> #dui_node{}.
clients_view(State) ->
    Lines = [client_line(C) || C <- dui_redis_state:clients(State)],
    lines_view(State, <<"Clients">>, <<"ID     addr                   age   db  cmd">>, Lines,
               <<" j/k nav   r refresh   esc back">>).

-spec client_line(map()) -> binary().
client_line(C) ->
    iolist_to_binary(io_lib:format("~-6b ~-22s ~-5b ~-3b ~s",
        [maps:get(id, C, 0), to_bin(maps:get(addr, C, <<>>)), maps:get(age, C, 0),
         maps:get(db, C, 0), to_bin(maps:get(cmd, C, <<>>))])).

-spec memory_view(#dui_state{}) -> #dui_node{}.
memory_view(State) ->
    Stats = case dui_redis_state:memory_stats(State) of
        undefined -> #{};
        S -> S
    end,
    {Rows, Cols} = dui_redis_state:size(State),
    Height = max(6, Rows - 4),
    LeftW = (Cols * 55) div 100,
    RightW = max(20, Cols - LeftW - 1),
    Frag = to_float(maps:get(frag_ratio, Stats, <<>>)),
    StatsContent = [
        educkui_render_node:text(kv(<<"used">>, maps:get(used, Stats, <<>>))),
        educkui_render_node:text(kv(<<"peak">>, maps:get(peak, Stats, <<>>))),
        educkui_render_node:text(kv(<<"rss">>, maps:get(rss, Stats, <<>>))),
        educkui_render_node:text(kv(<<"frag bytes">>, maps:get(frag_bytes, Stats, <<>>))),
        educkui_render_node:text(kv(<<"lua">>, maps:get(lua, Stats, <<>>))),
        educkui_render_node:text(<<"  frag ratio">>),
        gauge_row(clamp01(Frag), max(10, LeftW - 2), dui_redis_theme:info())
    ],
    TopContent = [educkui_render_node:text(top_key_line(K))
                  || K <- maps:get(top_keys, Stats, [])],
    educkui_render_node:stack(vertical, [
        educkui_render_node:stack(horizontal, [
            panel(<<"Memory Stats">>, StatsContent, LeftW, Height),
            panel(<<"Top Keys by Memory">>, TopContent, RightW, Height)
        ]),
        footer(<<" j/k nav   r refresh   esc back">>)
    ]).

-spec top_key_line(map()) -> binary().
top_key_line(K) ->
    iolist_to_binary(io_lib:format("~-40s ~-10s ~s",
        [to_bin(maps:get(key, K, <<>>)),
         dui_redis_preview:type_label(maps:get(type, K, string)),
         dui_redis_fmt:bytes(maps:get(size, K, 0))])).

-spec expiring_view(#dui_state{}) -> #dui_node{}.
expiring_view(State) ->
    Lines = [expiring_line(K) || K <- dui_redis_state:expiring(State)],
    lines_view(State, <<"Expiring Keys">>,
               <<"Key                                       TTL">>, Lines,
               <<" j/k nav   r refresh   esc back">>).

-spec expiring_line(map()) -> binary().
expiring_line(K) ->
    iolist_to_binary(io_lib:format("~-40s ~s",
        [to_bin(maps:get(key, K, <<>>)),
         dui_redis_fmt:ttl_render(maps:get(ttl, K, -1))])).

-spec channels_view(#dui_state{}) -> #dui_node{}.
channels_view(State) ->
    Lines = dui_redis_state:channels(State),
    lines_view(State, <<"Pub/Sub Channels">>, <<"Channel">>, Lines,
               <<" j/k nav   enter publish   r refresh   esc back">>).

-spec redis_config_view(#dui_state{}) -> #dui_node{}.
redis_config_view(State) ->
    Lines = [config_line(P) || P <- dui_redis_state:config_params(State)],
    lines_view(State, <<"Redis Config">>, <<"Parameter                        Value">>, Lines,
               <<" j/k nav   enter edit   r refresh   esc back">>).

-spec config_line({binary(), binary()}) -> binary().
config_line({K, V}) ->
    iolist_to_binary(io_lib:format("~-32s ~s", [K, to_bin(V)])).

-spec cluster_view(#dui_state{}) -> #dui_node{}.
cluster_view(State) ->
    Lines = [cluster_line(N) || N <- dui_redis_state:cluster_nodes(State)],
    lines_view(State, <<"Cluster Info">>, <<"Role      Addr                  Slots">>, Lines,
               <<" j/k nav   r refresh   esc back">>).

-spec cluster_line(map()) -> binary().
cluster_line(N) ->
    iolist_to_binary(io_lib:format("~-9s ~-21s ~s",
        [to_bin(maps:get(role, N, <<"unknown">>)),
         to_bin(maps:get(addr, N, <<>>)),
         iolist_to_binary(lists:join(<<",">>, [to_bin(S) || S <- maps:get(slots, N, [])]))])).

-spec groups_view(#dui_state{}) -> #dui_node{}.
groups_view(State) ->
    Lines = [group_line(G) || G <- dui_redis_state:groups(State)],
    lines_view(State, <<"Connection Groups">>, <<"Name                 Connections">>, Lines,
               <<" esc back">>).

-spec group_line(map()) -> binary().
group_line(G) ->
    iolist_to_binary(io_lib:format("~-20s ~s",
        [to_bin(maps:get(name, G, <<>>)),
         iolist_to_binary(lists:join(<<",">>, [to_bin(C) || C <- maps:get(connections, G, [])]))])).

-spec metrics_view(#dui_state{}) -> #dui_node{}.
metrics_view(State) ->
    Metrics = dui_redis_state:metrics(State),
    Current = case Metrics of
        [] -> #{};
        [H | _] -> H
    end,
    Ops = lists:reverse([maps:get(ops, M, 0) || M <- Metrics]),
    Mem = lists:reverse([maps:get(used_memory, M, 0) || M <- Metrics]),
    HitRate = hit_rate(Current),
    {Rows, Cols} = dui_redis_state:size(State),
    TopH = 8,
    ChartH = max(5, Rows - 13),
    LeftW = (Cols * 55) div 100,
    RightW = max(20, Cols - LeftW - 1),
    OverviewContent = [
        educkui_render_node:text(kv(<<"ops/sec">>, maps:get(ops, Current, 0))),
        educkui_render_node:text(kv(<<"clients">>, maps:get(clients, Current, 0))),
        educkui_render_node:text(kv(<<"blocked">>, maps:get(blocked, Current, 0))),
        educkui_render_node:text(kv(<<"hits/misses">>,
            iolist_to_binary(io_lib:format("~b / ~b",
                [maps:get(hits, Current, 0), maps:get(misses, Current, 0)])))),
        educkui_render_node:text(kv(<<"used memory">>,
            dui_redis_fmt:bytes(maps:get(used_memory, Current, 0))))
    ],
    HitContent = [
        educkui_render_node:text(<<"  hit rate: ", (pct(HitRate))/binary>>),
        gauge_row(HitRate, max(10, RightW - 2), dui_redis_theme:success())
    ],
    ChartInner = max(1, ChartH - 3),
    OpsCard = panel(<<"Ops/sec">>, [
        educkui_render_node:height(
            educkui_render_node:widget(educkui_widget_line_chart, #{
                values => nonempty(Ops), style => dui_redis_theme:info()
            }), ChartInner)
    ], LeftW, ChartH),
    MemCard = panel(<<"Memory">>, [
        educkui_render_node:height(
            educkui_render_node:widget(educkui_widget_line_chart, #{
                values => nonempty(Mem), style => dui_redis_theme:success()
            }), ChartInner)
    ], RightW, ChartH),
    educkui_render_node:stack(vertical, [
        screen_header(<<"Live Metrics">>),
        educkui_render_node:stack(horizontal, [
            panel(<<"Overview">>, OverviewContent, LeftW, TopH),
            panel(<<"Hit Rate">>, HitContent, RightW, TopH)
        ]),
        educkui_render_node:stack(horizontal, [OpsCard, MemCard]),
        footer(<<" r refresh   esc back">>)
    ]).

-spec hit_rate(map()) -> float().
hit_rate(#{hits := H, misses := M}) when H + M > 0 -> H / (H + M);
hit_rate(_) -> 0.0.

-spec pct(float()) -> binary().
pct(F) ->
    iolist_to_binary([io_lib:format("~.1f", [F * 100]), "%"]).

-spec nonempty([number()]) -> [number()].
nonempty([]) -> [0];
nonempty(L) -> L.

-spec to_float(term()) -> float().
to_float(F) when is_float(F) -> F;
to_float(I) when is_integer(I) -> float(I);
to_float(B) when is_binary(B) ->
    S = binary_to_list(B),
    case string:to_float(S) of
        {error, no_float} ->
            case string:to_integer(S) of
                {error, _} -> 0.0;
                {I, _} -> float(I)
            end;
        {F, _} -> F
    end;
to_float(_) -> 0.0.

-spec clamp01(number()) -> float().
clamp01(F) when F < 0.0 -> 0.0;
clamp01(F) when F > 1.0 -> 1.0;
clamp01(F) -> float(F).

-spec kv(binary() | string(), term()) -> binary().
kv(Label, Value) ->
    iolist_to_binary(io_lib:format("  ~-14s ~s", [Label, to_bin(Value)])).

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
    modal(State, Title, [educkui_render_node:text(Content)], 50).

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
    Visible = keys_visible(State),
    Keys = dui_redis_state:keys(State),
    Total = length(Keys),
    Selected = min(dui_redis_state:selected_key(State), max(0, Total - 1)),
    {Offset, _} = educkui_widget_list:visible_range(Total, Selected, Visible),
    Window = lists:sublist(Keys, Offset + 1, Visible),
    TypeW = 12,
    KeyW = max(20, Width - TypeW - 9),
    TitleNode = educkui_render_node:text(keys_title(State), dui_redis_theme:title()),
    FilterNode = educkui_render_node:widget(educkui_widget_text_view,
        #{lines => [filter_spans(State)]}),
    HeaderNode = educkui_render_node:text(header_line(KeyW, TypeW), dui_redis_theme:header()),
    SepNode = educkui_render_node:text(
        binary:copy(<<226, 148, 128>>, min(Width, 200)), dui_redis_theme:dim()),
    ListNode = case Window of
        [] ->
            educkui_render_node:height(
                educkui_render_node:text(<<"  No keys found.">>, dui_redis_theme:dim()),
                max(1, Visible));
        _ ->
            Lines = [key_spans(K, Offset + I =:= Selected, KeyW, TypeW)
                     || {K, I} <- lists:zip(Window, lists:seq(0, length(Window) - 1))],
            educkui_render_node:height(
                educkui_render_node:widget(educkui_widget_text_view, #{lines => Lines}),
                max(1, Visible))
    end,
    More = case dui_redis_state:key_cursor(State) of
        0 -> [];
        _ -> [educkui_render_node:text(<<"  ... l:more">>, dui_redis_theme:dim())]
    end,
    educkui_render_node:stack(vertical, [
        TitleNode,
        educkui_render_node:text(<<>>),
        FilterNode,
        educkui_render_node:text(<<>>),
        HeaderNode,
        SepNode,
        ListNode
        | More
    ]).

-spec keys_title(#dui_state{}) -> binary().
keys_title(State) ->
    Conn = dui_redis_state:current_conn(State),
    Name = case Conn of
        undefined -> <<"Redis">>;
        _ -> to_bin(maps:get(name, Conn, <<"Redis">>))
    end,
    Total = dui_redis_state:total_keys(State),
    iolist_to_binary(io_lib:format("Keys - ~s  [Total: ~b]", [Name, Total])).

-spec filter_spans(#dui_state{}) -> [{binary(), term()}].
filter_spans(State) ->
    Pattern = displayed_pattern(State),
    Cursor = case dui_redis_state:filter_active(State) of
        true -> <<"_">>;
        false -> <<>>
    end,
    [{<<"Filter: ">>, dui_redis_theme:key_accent()},
     {<<Pattern/binary, Cursor/binary>>, dui_redis_theme:normal()}].

-spec header_line(pos_integer(), pos_integer()) -> binary().
header_line(KeyW, TypeW) ->
    <<"  ", (dui_redis_theme:pad(<<"Key">>, KeyW))/binary, "  ",
      (dui_redis_theme:pad(<<"Type">>, TypeW))/binary, "  TTL">>.

-spec key_spans(map(), boolean(), pos_integer(), pos_integer()) -> [{binary(), term()}].
key_spans(K, Selected, KeyW, TypeW) ->
    Name = dui_redis_theme:pad(display_name(K), KeyW),
    Type = maps:get(type, K, string),
    TypeBin = dui_redis_theme:pad(dui_redis_preview:type_label(Type), TypeW),
    Ttl = dui_redis_fmt:ttl_render(maps:get(ttl, K, -1)),
    case Selected of
        true ->
            [{<<226, 150, 182, 32>>, dui_redis_theme:selected()},
             {Name, dui_redis_theme:selected()},
             {<<"  ">>, undefined},
             {TypeBin, dui_redis_theme:type_style_bold(Type)},
             {<<"  ">>, undefined},
             {Ttl, dui_redis_theme:normal()}];
        false ->
            [{<<"  ">>, undefined},
             {Name, dui_redis_theme:normal()},
             {<<"  ">>, undefined},
             {TypeBin, dui_redis_theme:type_style(Type)},
             {<<"  ">>, undefined},
             {Ttl, dui_redis_theme:dim()}]
    end.

-spec preview_panel(#dui_state{}) -> #dui_node{}.
preview_panel(State) ->
    Border = dui_redis_theme:border(),
    case dui_redis_state:preview_value(State) of
        undefined ->
            educkui_render_node:widget(educkui_widget_text_view, #{lines => [
                [{<<226,148,130,32>>, Border}, {<<"Preview">>, dui_redis_theme:title()}],
                [{<<226,148,130,32>>, Border}, {<<"(select a key)">>, dui_redis_theme:dim()}]
            ]});
        Value ->
            Summary = dui_redis_preview:summary(Value),
            Type = maps:get(type, Value, string),
            Body = case json_text(Value) of
                {true, JsonText} ->
                    [[{<<226,148,130,32>>, Border} | Spans]
                     || Spans <- dui_redis_json:lines(JsonText)];
                false ->
                    [[{<<226,148,130,32>>, Border}, {L, dui_redis_theme:normal()}]
                     || L <- dui_redis_preview:lines(Value, 200)]
            end,
            educkui_render_node:widget(educkui_widget_text_view, #{lines => [
                [{<<226,148,130,32>>, Border}, {<<"Preview">>, dui_redis_theme:title()}],
                [{<<226,148,130,32>>, Border}, {Summary, dui_redis_theme:type_style_bold(Type)}],
                [{<<226,148,130>>, Border}]
                | Body
            ]})
    end.

-spec switch_db_view(#dui_state{}) -> #dui_node{}.
switch_db_view(State) ->
    Edit = dui_redis_state:db_input(State),
    Value = case Edit of
        undefined -> <<>>;
        _ -> educkui_lineedit:value(Edit)
    end,
    Content = [
        educkui_render_node:text(<<>>),
        educkui_render_node:text(<<"  db: ", Value/binary, "_">>, dui_redis_theme:info()),
        educkui_render_node:text(<<>>),
        footer(<<" enter switch   esc cancel">>)
    ],
    modal(State, <<"Switch Database">>, Content, 44).

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
    {LeftGroups, RightGroups} = lists:split(3, help_groups()),
    educkui_render_node:stack(vertical, [
        educkui_render_node:text(<<" Help">>, dui_redis_theme:title()),
        educkui_render_node:text(<<>>),
        educkui_render_node:stack(horizontal, [
            educkui_render_node:width(help_column(LeftGroups), 42),
            help_column(RightGroups)
        ])
    ]).

%% @doc Help content grouped by screen, split into two columns by the caller.
-spec help_groups() -> [{binary(), [{binary(), binary()}]}].
help_groups() ->
    [{<<"General">>, [
        {<<"?">>, <<"toggle help">>},
        {<<"q">>, <<"quit">>},
        {<<"Ctrl+C">>, <<"quit">>},
        {<<"Esc">>, <<"back / cancel">>}
     ]},
     {<<"Connections">>, [
        {<<"j/k">>, <<"navigate">>},
        {<<"Enter">>, <<"connect">>},
        {<<"a/n">>, <<"add connection">>},
        {<<"e">>, <<"edit connection">>},
        {<<"d">>, <<"delete connection">>},
        {<<"r">>, <<"reload from disk">>}
     ]},
     {<<"Form">>, [
        {<<"Tab">>, <<"next field">>},
        {<<"Space">>, <<"toggle checkbox">>},
        {<<"Enter">>, <<"save">>},
        {<<"Ctrl+T">>, <<"test connection">>},
        {<<"Esc">>, <<"cancel">>}
     ]},
     {<<"Keys">>, [
        {<<"j/k">>, <<"navigate">>},
        {<<"Enter">>, <<"view">>},
        {<<"/">>, <<"filter">>},
        {<<"s/S">>, <<"sort / reverse">>},
        {<<"r">>, <<"refresh">>},
        {<<"D">>, <<"switch db">>},
        {<<"l">>, <<"load more">>},
        {<<"Esc">>, <<"disconnect">>}
     ]},
     {<<"Detail">>, [
        {<<"j/k">>, <<"scroll">>},
        {<<"e">>, <<"edit">>},
        {<<"a">>, <<"add member">>},
        {<<"x">>, <<"remove member">>},
        {<<"t">>, <<"set ttl">>},
        {<<"R">>, <<"rename">>},
        {<<"c">>, <<"copy">>},
        {<<"d">>, <<"delete">>},
        {<<"r">>, <<"refresh">>},
        {<<"Esc">>, <<"back">>}
     ]},
     {<<"Editor">>, [
        {<<"arrows">>, <<"move cursor">>},
        {<<"Enter">>, <<"newline">>},
        {<<"Ctrl+S">>, <<"save">>},
        {<<"F2">>, <<"save (fallback)">>},
        {<<"Esc">>, <<"cancel">>}
     ]}].

-spec help_column([{binary(), [{binary(), binary()}]}]) -> #dui_node{}.
help_column(Groups) ->
    Lines = lists:flatmap(
        fun({Title, Entries}) ->
            [[{<<" ", Title/binary>>, dui_redis_theme:key_accent()}]]
            ++ [help_line(K, D) || {K, D} <- Entries]
            ++ [[]]
        end, Groups),
    educkui_render_node:widget(educkui_widget_text_view, #{lines => Lines}).

-spec help_line(binary(), binary()) -> [{binary(), #dui_style{}}].
help_line(Key, Desc) ->
    [{dui_redis_theme:pad(Key, 11), dui_redis_theme:help_key()},
     {<<"  ", Desc/binary>>, dui_redis_theme:help()}].

-spec status_bar(#dui_state{}) -> #dui_node{}.
status_bar(State) ->
    case dui_redis_state:status(State) of
        undefined -> hint_bar(State);
        {info, Msg} -> bar_text(Msg, dui_redis_theme:info());
        {error, Msg} -> bar_text(Msg, dui_redis_theme:error())
    end.

-spec bar_text(binary(), #dui_style{}) -> #dui_node{}.
bar_text(Text, Style) ->
    educkui_render_node:height(educkui_render_node:text(Text, Style), 1).

%% @doc Default status bar: connection state, database, terminal size and
%% global shortcuts as colored spans.
-spec hint_bar(#dui_state{}) -> #dui_node{}.
hint_bar(State) ->
    {Rows, Cols} = dui_redis_state:size(State),
    {StatusText, StatusStyle} = case dui_redis_state:connected(State) of
        true -> {<<" connected">>, dui_redis_theme:success()};
        false -> {<<" disconnected">>, dui_redis_theme:dim()}
    end,
    DbSpans = case dui_redis_state:connected(State) of
        true ->
            Db = case dui_redis_state:current_conn(State) of
                undefined -> 0;
                Conn -> maps:get(db, Conn, 0)
            end,
            [{<<"   db ">>, dui_redis_theme:dim()},
             {integer_to_binary(Db), dui_redis_theme:title()}];
        false ->
            []
    end,
    Size = iolist_to_binary(io_lib:format("~bx~b", [Cols, Rows])),
    Spans = [{StatusText, StatusStyle}]
        ++ DbSpans
        ++ [{<<"   ">>, dui_redis_theme:dim()},
            {Size, dui_redis_theme:meta_dim()},
            {<<"   ">>, dui_redis_theme:dim()},
            {<<"? help   q quit">>, dui_redis_theme:help()}],
    educkui_render_node:height(
        educkui_render_node:widget(educkui_widget_text_view, #{lines => [Spans]}), 1).

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
