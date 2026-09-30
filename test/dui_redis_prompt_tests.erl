-module(dui_redis_prompt_tests).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    P = dui_redis_prompt:new([{a, <<"A">>, false}, {b, <<"B">>, true}]),
    ?assertEqual(<<>>, dui_redis_prompt:value(P, a)),
    ?assertEqual(0, dui_redis_prompt:focus(P)),
    ?assertEqual({a, <<"A">>, false}, dui_redis_prompt:focused_field(P)).

defaults_test() ->
    P = dui_redis_prompt:new([{name, <<"Name">>, false}], #{name => <<"x">>}),
    ?assertEqual(<<"x">>, dui_redis_prompt:value(P, name)).

insert_test() ->
    P0 = dui_redis_prompt:new([{a, <<"A">>, false}]),
    P1 = dui_redis_prompt:insert(<<"hi">>, P0),
    ?assertEqual(<<"hi">>, dui_redis_prompt:value(P1, a)),
    ?assertEqual(2, dui_redis_prompt:cursor(P1)).

backspace_test() ->
    P0 = dui_redis_prompt:insert(<<"abc">>, dui_redis_prompt:new([{a, <<"A">>, false}])),
    P1 = dui_redis_prompt:backspace(P0),
    ?assertEqual(<<"ab">>, dui_redis_prompt:value(P1, a)).

focus_cycles_test() ->
    P0 = dui_redis_prompt:new([{a, <<"A">>, false}, {b, <<"B">>, false}]),
    P1 = dui_redis_prompt:focus_next(P0),
    ?assertEqual(1, dui_redis_prompt:focus(P1)),
    P2 = dui_redis_prompt:focus_next(P1),
    ?assertEqual(0, dui_redis_prompt:focus(P2)),
    P3 = dui_redis_prompt:focus_prev(P0),
    ?assertEqual(1, dui_redis_prompt:focus(P3)).

focus_resets_cursor_to_end_test() ->
    P0 = dui_redis_prompt:new([{a, <<"A">>, false}, {b, <<"B">>, false}], #{b => <<"xy">>}),
    P1 = dui_redis_prompt:focus_next(P0),
    ?assertEqual(2, dui_redis_prompt:cursor(P1)).

to_map_test() ->
    P0 = dui_redis_prompt:new([{a, <<"A">>, false}, {b, <<"B">>, false}], #{b => <<"v">>}),
    P1 = dui_redis_prompt:insert(<<"x">>, P0),
    ?assertEqual(#{a => <<"x">>, b => <<"v">>}, dui_redis_prompt:to_map(P1)).

move_test() ->
    P0 = dui_redis_prompt:new([{a, <<"A">>, false}], #{a => <<"ab">>}),
    P1 = dui_redis_prompt:move(left, P0),
    ?assertEqual(1, dui_redis_prompt:cursor(P1)).
