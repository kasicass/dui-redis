-module(dui_redis_form_tests).

-include_lib("eunit/include/eunit.hrl").

new_add_defaults_test() ->
    F = dui_redis_form:new_add(),
    ?assertEqual(add, dui_redis_form:mode(F)),
    ?assertEqual(undefined, dui_redis_form:id(F)),
    ?assertEqual(<<"localhost">>, dui_redis_form:value(F, host)),
    ?assertEqual(<<"6379">>, dui_redis_form:value(F, port)),
    ?assertEqual(<<"0">>, dui_redis_form:value(F, db)),
    ?assertEqual(false, dui_redis_form:value(F, cluster)).

new_edit_populates_test() ->
    Conn = #{id => 7, name => <<"Local">>, host => <<"127.0.0.1">>,
             port => 6380, username => <<"u">>, password => <<"p">>,
             db => 2, use_cluster => true},
    F = dui_redis_form:new_edit(Conn),
    ?assertEqual(edit, dui_redis_form:mode(F)),
    ?assertEqual(7, dui_redis_form:id(F)),
    ?assertEqual(<<"Local">>, dui_redis_form:value(F, name)),
    ?assertEqual(<<"127.0.0.1">>, dui_redis_form:value(F, host)),
    ?assertEqual(<<"6380">>, dui_redis_form:value(F, port)),
    ?assertEqual(<<"2">>, dui_redis_form:value(F, db)),
    ?assertEqual(true, dui_redis_form:value(F, cluster)).

insert_appends_at_cursor_test() ->
    F0 = dui_redis_form:new_add(),
    F1 = dui_redis_form:insert(<<"My">>, F0),
    ?assertEqual(<<"My">>, dui_redis_form:value(F1, name)),
    ?assertEqual(2, dui_redis_form:cursor(F1)).

focus_cycles_test() ->
    F0 = dui_redis_form:new_add(),
    F1 = dui_redis_form:focus_next(F0),
    ?assertEqual(1, dui_redis_form:focus(F1)),
    F2 = dui_redis_form:focus_prev(F1),
    ?assertEqual(0, dui_redis_form:focus(F2)),
    %% wrap-around
    Count = length(dui_redis_form:fields()),
    F3 = dui_redis_form:focus_prev(F0),
    ?assertEqual(Count - 1, dui_redis_form:focus(F3)).

backspace_test() ->
    F0 = dui_redis_form:new_add(),
    F1 = dui_redis_form:insert(<<"abc">>, F0),
    F2 = dui_redis_form:backspace(F1),
    ?assertEqual(<<"ab">>, dui_redis_form:value(F2, name)).

toggle_cluster_test() ->
    F0 = dui_redis_form:new_add(),
    %% move focus to the cluster checkbox (index 5)
    F1 = lists:foldl(fun(_, F) -> dui_redis_form:focus_next(F) end, F0, lists:seq(1, 5)),
    ?assertEqual(<<"Cluster Mode">>, maps:get(label, dui_redis_form:focused_field(F1))),
    F2 = dui_redis_form:toggle(F1),
    ?assertEqual(true, dui_redis_form:value(F2, cluster)).

validate_required_test() ->
    F0 = dui_redis_form:new_add(),
    ?assertEqual({error, <<"Name is required">>}, dui_redis_form:validate(F0)),
    F1 = dui_redis_form:insert(<<"x">>, F0),
    ?assertEqual(ok, dui_redis_form:validate(F1)).

validate_bad_port_test() ->
    F0 = dui_redis_form:new_add(),
    F1 = dui_redis_form:insert(<<"n">>, F0),
    %% focus port (index 2) and clear it
    F2 = dui_redis_form:focus_next(dui_redis_form:focus_next(F1)),
    F3 = lists:foldl(fun(_, F) -> dui_redis_form:backspace(F) end, F2, lists:seq(1, 4)),
    ?assertEqual({error, <<"Port must be a positive integer">>}, dui_redis_form:validate(F3)).

to_connection_test() ->
    F0 = dui_redis_form:new_add(),
    F1 = dui_redis_form:insert(<<"Local">>, F0),
    Conn = dui_redis_form:to_connection(F1),
    ?assertEqual(<<"Local">>, maps:get(name, Conn)),
    ?assertEqual(<<"localhost">>, maps:get(host, Conn)),
    ?assertEqual(6379, maps:get(port, Conn)),
    ?assertEqual(0, maps:get(db, Conn)),
    ?assertEqual(false, maps:get(use_cluster, Conn)),
    ?assertEqual(<<>>, maps:get(username, Conn)),
    ?assertEqual(<<>>, maps:get(password, Conn)).

set_error_clears_on_edit_test() ->
    F0 = dui_redis_form:set_error(<<"boom">>, dui_redis_form:new_add()),
    ?assertEqual(<<"boom">>, dui_redis_form:error(F0)),
    F1 = dui_redis_form:insert(<<"a">>, F0),
    ?assertEqual(undefined, dui_redis_form:error(F1)).
