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
    keys/1,
    set_keys/3,
    replace_keys/2,
    selected_key/1,
    set_selected_key/2,
    key_cursor/1,
    set_key_cursor/2,
    key_pattern/1,
    set_key_pattern/2,
    total_keys/1,
    set_total_keys/2,
    sort_by/1,
    sort_asc/1,
    set_sort_by/2,
    toggle_sort_asc/1,
    filter_active/1,
    set_filter_active/2,
    filter_edit/1,
    set_filter_edit/2,
    search_seq/1,
    bump_search_seq/1,
    preview_key/1,
    set_preview/3,
    preview_value/1,
    loading_keys/1,
    set_loading_keys/2,
    db_input/1,
    set_db_input/2,
    current_key/1,
    set_current_key/2,
    current_value/1,
    set_current_value/2,
    detail_scroll/1,
    set_detail_scroll/2,
    editor/1,
    set_editor/2,
    prompt/1,
    set_prompt/2,
    prompt_purpose/1,
    set_prompt_purpose/2,
    history/1,
    set_history/2,
    results/1,
    set_results/3,
    selected_result/1,
    set_selected_result/2,
    results_title/1,
    results_purpose/1,
    tree_nodes/1,
    set_tree_nodes/2,
    tree_expanded/1,
    toggle_tree_expanded/2,
    selected_tree/1,
    set_selected_tree/2,
    result_text/1,
    set_result_text/2,
    server_info/1,
    set_server_info/2,
    slow_log/1,
    set_slow_log/2,
    clients/1,
    set_clients/2,
    memory_stats/1,
    set_memory_stats/2,
    metrics/1,
    push_metric/2,
    clear_metrics/1,
    metrics_active/1,
    set_metrics_active/2,
    expiring/1,
    set_expiring/2,
    row_selected/1,
    set_row_selected/2,
    channels/1,
    set_channels/2,
    config_params/1,
    set_config_params/2,
    cluster_nodes/1,
    set_cluster_nodes/2,
    cluster/1,
    set_cluster/2,
    groups/1,
    set_groups/2,
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
        history = dui_redis_history:new(),
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

-spec keys(#dui_state{}) -> [map()].
keys(#dui_state{keys = Keys}) -> Keys.

%% @doc Replaces the key list. When `Cursor' is 0 the list is reset, otherwise
%% `Keys' are appended (paging).
-spec set_keys(#dui_state{}, [map()], integer()) -> #dui_state{}.
set_keys(#dui_state{keys = Existing} = State, Keys, 0) ->
    _ = Existing,
    State#dui_state{keys = Keys, selected_key = 0, loading_keys = false};
set_keys(#dui_state{keys = Existing} = State, Keys, _Cursor) ->
    State#dui_state{keys = Existing ++ Keys, loading_keys = false}.

-spec replace_keys(#dui_state{}, [map()]) -> #dui_state{}.
replace_keys(State, Keys) -> State#dui_state{keys = Keys}.

-spec selected_key(#dui_state{}) -> non_neg_integer().
selected_key(#dui_state{selected_key = N}) -> N.

-spec set_selected_key(#dui_state{}, non_neg_integer()) -> #dui_state{}.
set_selected_key(State, N) -> State#dui_state{selected_key = max(0, N)}.

-spec key_cursor(#dui_state{}) -> non_neg_integer().
key_cursor(#dui_state{key_cursor = C}) -> C.

-spec set_key_cursor(#dui_state{}, non_neg_integer()) -> #dui_state{}.
set_key_cursor(State, C) -> State#dui_state{key_cursor = max(0, C)}.

-spec key_pattern(#dui_state{}) -> binary().
key_pattern(#dui_state{key_pattern = P}) -> P.

-spec set_key_pattern(#dui_state{}, binary()) -> #dui_state{}.
set_key_pattern(State, Pattern) -> State#dui_state{key_pattern = Pattern}.

-spec total_keys(#dui_state{}) -> integer().
total_keys(#dui_state{total_keys = N}) -> N.

-spec set_total_keys(#dui_state{}, integer()) -> #dui_state{}.
set_total_keys(State, N) -> State#dui_state{total_keys = N}.

-spec sort_by(#dui_state{}) -> key | type | ttl.
sort_by(#dui_state{sort_by = By}) -> By.

-spec sort_asc(#dui_state{}) -> boolean().
sort_asc(#dui_state{sort_asc = Asc}) -> Asc.

-spec set_sort_by(#dui_state{}, key | type | ttl) -> #dui_state{}.
set_sort_by(State, By) -> State#dui_state{sort_by = By}.

-spec toggle_sort_asc(#dui_state{}) -> #dui_state{}.
toggle_sort_asc(#dui_state{sort_asc = Asc} = State) -> State#dui_state{sort_asc = not Asc}.

-spec filter_active(#dui_state{}) -> boolean().
filter_active(#dui_state{filter_active = B}) -> B.

-spec set_filter_active(#dui_state{}, boolean()) -> #dui_state{}.
set_filter_active(State, B) -> State#dui_state{filter_active = B}.

-spec filter_edit(#dui_state{}) -> term() | undefined.
filter_edit(#dui_state{filter_edit = E}) -> E.

-spec set_filter_edit(#dui_state{}, term()) -> #dui_state{}.
set_filter_edit(State, Edit) -> State#dui_state{filter_edit = Edit}.

-spec search_seq(#dui_state{}) -> integer().
search_seq(#dui_state{search_seq = S}) -> S.

-spec bump_search_seq(#dui_state{}) -> {integer(), #dui_state{}}.
bump_search_seq(#dui_state{search_seq = S} = State) ->
    {S + 1, State#dui_state{search_seq = S + 1}}.

-spec preview_key(#dui_state{}) -> binary().
preview_key(#dui_state{preview_key = K}) -> K.

-spec set_preview(#dui_state{}, binary(), map() | undefined) -> #dui_state{}.
set_preview(State, Key, Value) -> State#dui_state{preview_key = Key, preview_value = Value}.

-spec preview_value(#dui_state{}) -> map() | undefined.
preview_value(#dui_state{preview_value = V}) -> V.

-spec loading_keys(#dui_state{}) -> boolean().
loading_keys(#dui_state{loading_keys = B}) -> B.

-spec set_loading_keys(#dui_state{}, boolean()) -> #dui_state{}.
set_loading_keys(State, B) -> State#dui_state{loading_keys = B}.

-spec db_input(#dui_state{}) -> term() | undefined.
db_input(#dui_state{db_input = E}) -> E.

-spec set_db_input(#dui_state{}, term()) -> #dui_state{}.
set_db_input(State, Edit) -> State#dui_state{db_input = Edit}.

-spec current_key(#dui_state{}) -> map() | undefined.
current_key(#dui_state{current_key = K}) -> K.

-spec set_current_key(#dui_state{}, map() | undefined) -> #dui_state{}.
set_current_key(State, Key) -> State#dui_state{current_key = Key}.

-spec current_value(#dui_state{}) -> map() | undefined.
current_value(#dui_state{current_value = V}) -> V.

-spec set_current_value(#dui_state{}, map() | undefined) -> #dui_state{}.
set_current_value(State, Value) -> State#dui_state{current_value = Value}.

-spec detail_scroll(#dui_state{}) -> non_neg_integer().
detail_scroll(#dui_state{detail_scroll = N}) -> N.

-spec set_detail_scroll(#dui_state{}, non_neg_integer()) -> #dui_state{}.
set_detail_scroll(State, N) -> State#dui_state{detail_scroll = max(0, N)}.

-spec editor(#dui_state{}) -> term() | undefined.
editor(#dui_state{editor = E}) -> E.

-spec set_editor(#dui_state{}, term()) -> #dui_state{}.
set_editor(State, Editor) -> State#dui_state{editor = Editor}.

-spec prompt(#dui_state{}) -> term() | undefined.
prompt(#dui_state{prompt = P}) -> P.

-spec set_prompt(#dui_state{}, term()) -> #dui_state{}.
set_prompt(State, Prompt) -> State#dui_state{prompt = Prompt}.

-spec prompt_purpose(#dui_state{}) -> term() | undefined.
prompt_purpose(#dui_state{prompt_purpose = P}) -> P.

-spec set_prompt_purpose(#dui_state{}, term()) -> #dui_state{}.
set_prompt_purpose(State, Purpose) -> State#dui_state{prompt_purpose = Purpose}.

-spec history(#dui_state{}) -> dui_redis_history:history() | undefined.
history(#dui_state{history = H}) -> H.

-spec set_history(#dui_state{}, dui_redis_history:history()) -> #dui_state{}.
set_history(State, Hist) -> State#dui_state{history = Hist}.

-spec results(#dui_state{}) -> [map()].
results(#dui_state{results = R}) -> R.

-spec set_results(#dui_state{}, [map()], {binary(), atom()}) -> #dui_state{}.
set_results(State, Results, {Title, Purpose}) ->
    State#dui_state{results = Results, selected_result = 0,
                    results_title = Title, results_purpose = Purpose}.

-spec selected_result(#dui_state{}) -> non_neg_integer().
selected_result(#dui_state{selected_result = N}) -> N.

-spec set_selected_result(#dui_state{}, non_neg_integer()) -> #dui_state{}.
set_selected_result(State, N) -> State#dui_state{selected_result = max(0, N)}.

-spec results_title(#dui_state{}) -> binary().
results_title(#dui_state{results_title = T}) -> T.

-spec results_purpose(#dui_state{}) -> atom() | undefined.
results_purpose(#dui_state{results_purpose = P}) -> P.

-spec tree_nodes(#dui_state{}) -> [map()].
tree_nodes(#dui_state{tree_nodes = N}) -> N.

-spec set_tree_nodes(#dui_state{}, [map()]) -> #dui_state{}.
set_tree_nodes(State, Nodes) -> State#dui_state{tree_nodes = Nodes, selected_tree = 0}.

-spec tree_expanded(#dui_state{}) -> [binary()].
tree_expanded(#dui_state{tree_expanded = E}) -> E.

-spec toggle_tree_expanded(#dui_state{}, binary()) -> #dui_state{}.
toggle_tree_expanded(#dui_state{tree_expanded = Expanded} = State, Path) ->
    New = case lists:member(Path, Expanded) of
        true -> lists:delete(Path, Expanded);
        false -> [Path | Expanded]
    end,
    State#dui_state{tree_expanded = New}.

-spec selected_tree(#dui_state{}) -> non_neg_integer().
selected_tree(#dui_state{selected_tree = N}) -> N.

-spec set_selected_tree(#dui_state{}, non_neg_integer()) -> #dui_state{}.
set_selected_tree(State, N) -> State#dui_state{selected_tree = max(0, N)}.

-spec result_text(#dui_state{}) -> binary() | undefined.
result_text(#dui_state{result_text = T}) -> T.

-spec set_result_text(#dui_state{}, binary() | undefined) -> #dui_state{}.
set_result_text(State, Text) -> State#dui_state{result_text = Text}.

-spec server_info(#dui_state{}) -> map() | undefined.
server_info(#dui_state{server_info = I}) -> I.

-spec set_server_info(#dui_state{}, map()) -> #dui_state{}.
set_server_info(State, Info) -> State#dui_state{server_info = Info, loading = false}.

-spec slow_log(#dui_state{}) -> [map()].
slow_log(#dui_state{slow_log = L}) -> L.

-spec set_slow_log(#dui_state{}, [map()]) -> #dui_state{}.
set_slow_log(State, L) -> State#dui_state{slow_log = L, row_selected = 0, loading = false}.

-spec clients(#dui_state{}) -> [map()].
clients(#dui_state{clients = C}) -> C.

-spec set_clients(#dui_state{}, [map()]) -> #dui_state{}.
set_clients(State, C) -> State#dui_state{clients = C, row_selected = 0, loading = false}.

-spec memory_stats(#dui_state{}) -> map() | undefined.
memory_stats(#dui_state{memory_stats = M}) -> M.

-spec set_memory_stats(#dui_state{}, map()) -> #dui_state{}.
set_memory_stats(State, M) -> State#dui_state{memory_stats = M, loading = false}.

-spec metrics(#dui_state{}) -> [map()].
metrics(#dui_state{metrics = M}) -> M.

%% @doc Appends a metric sample, keeping the most recent 60.
-spec push_metric(#dui_state{}, map()) -> #dui_state{}.
push_metric(#dui_state{metrics = Metrics} = State, Metric) ->
    State#dui_state{metrics = lists:sublist([Metric | Metrics], 60)}.

-spec clear_metrics(#dui_state{}) -> #dui_state{}.
clear_metrics(State) -> State#dui_state{metrics = []}.

-spec metrics_active(#dui_state{}) -> boolean().
metrics_active(#dui_state{metrics_active = B}) -> B.

-spec set_metrics_active(#dui_state{}, boolean()) -> #dui_state{}.
set_metrics_active(State, B) -> State#dui_state{metrics_active = B}.

-spec expiring(#dui_state{}) -> [map()].
expiring(#dui_state{expiring = E}) -> E.

-spec set_expiring(#dui_state{}, [map()]) -> #dui_state{}.
set_expiring(State, E) -> State#dui_state{expiring = E, row_selected = 0, loading = false}.

-spec row_selected(#dui_state{}) -> non_neg_integer().
row_selected(#dui_state{row_selected = N}) -> N.

-spec set_row_selected(#dui_state{}, non_neg_integer()) -> #dui_state{}.
set_row_selected(State, N) -> State#dui_state{row_selected = max(0, N)}.

-spec channels(#dui_state{}) -> [binary()].
channels(#dui_state{channels = C}) -> C.

-spec set_channels(#dui_state{}, [binary()]) -> #dui_state{}.
set_channels(State, C) -> State#dui_state{channels = C, row_selected = 0, loading = false}.

-spec config_params(#dui_state{}) -> [{binary(), binary()}].
config_params(#dui_state{config_params = P}) -> P.

-spec set_config_params(#dui_state{}, [{binary(), binary()}]) -> #dui_state{}.
set_config_params(State, P) -> State#dui_state{config_params = P, row_selected = 0, loading = false}.

-spec cluster_nodes(#dui_state{}) -> [map()].
cluster_nodes(#dui_state{cluster_nodes = N}) -> N.

-spec set_cluster_nodes(#dui_state{}, [map()]) -> #dui_state{}.
set_cluster_nodes(State, N) -> State#dui_state{cluster_nodes = N, row_selected = 0, loading = false}.

-spec cluster(#dui_state{}) -> map() | undefined.
cluster(#dui_state{cluster = C}) -> C.

-spec set_cluster(#dui_state{}, map()) -> #dui_state{}.
set_cluster(State, C) -> State#dui_state{cluster = C, loading = false}.

-spec groups(#dui_state{}) -> [map()].
groups(#dui_state{groups = G}) -> G.

-spec set_groups(#dui_state{}, [map()]) -> #dui_state{}.
set_groups(State, G) -> State#dui_state{groups = G, row_selected = 0, loading = false}.

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
