-module(dui_redis_editor_tests).

-include_lib("eunit/include/eunit.hrl").

new_test() ->
    Ed = dui_redis_editor:new(<<"a\nbc">>),
    ?assertEqual(<<"a\nbc">>, dui_redis_editor:value(Ed)),
    ?assertEqual(0, dui_redis_editor:row(Ed)),
    ?assertEqual(0, dui_redis_editor:col(Ed)),
    ?assertEqual(2, dui_redis_editor:line_count(Ed)).

insert_test() ->
    Ed = dui_redis_editor:insert(<<"x">>, dui_redis_editor:new(<<>>)),
    ?assertEqual(<<"x">>, dui_redis_editor:value(Ed)),
    ?assertEqual(1, dui_redis_editor:col(Ed)).

insert_in_middle_test() ->
    Ed0 = dui_redis_editor:set_cursor(0, 1, dui_redis_editor:new(<<"ab">>)),
    Ed1 = dui_redis_editor:insert(<<"X">>, Ed0),
    ?assertEqual(<<"aXb">>, dui_redis_editor:value(Ed1)),
    ?assertEqual(2, dui_redis_editor:col(Ed1)).

newline_test() ->
    Ed0 = dui_redis_editor:set_cursor(0, 1, dui_redis_editor:new(<<"ab">>)),
    Ed1 = dui_redis_editor:newline(Ed0),
    ?assertEqual(<<"a\nb">>, dui_redis_editor:value(Ed1)),
    ?assertEqual(1, dui_redis_editor:row(Ed1)),
    ?assertEqual(0, dui_redis_editor:col(Ed1)).

backspace_merges_lines_test() ->
    Ed0 = dui_redis_editor:set_cursor(1, 0, dui_redis_editor:new(<<"a\nb">>)),
    Ed1 = dui_redis_editor:backspace(Ed0),
    ?assertEqual(<<"ab">>, dui_redis_editor:value(Ed1)),
    ?assertEqual(0, dui_redis_editor:row(Ed1)),
    ?assertEqual(1, dui_redis_editor:col(Ed1)).

delete_merges_lines_test() ->
    Ed0 = dui_redis_editor:set_cursor(0, 1, dui_redis_editor:new(<<"a\nb">>)),
    Ed1 = dui_redis_editor:delete(Ed0),
    ?assertEqual(<<"ab">>, dui_redis_editor:value(Ed1)).

move_vertical_clamps_col_test() ->
    Ed0 = dui_redis_editor:set_cursor(0, 3, dui_redis_editor:new(<<"abcd\nx">>)),
    Ed1 = dui_redis_editor:move(down, Ed0),
    ?assertEqual(1, dui_redis_editor:row(Ed1)),
    ?assertEqual(1, dui_redis_editor:col(Ed1)).

home_end_test() ->
    Ed0 = dui_redis_editor:set_cursor(0, 1, dui_redis_editor:new(<<"abcd">>)),
    ?assertEqual(0, dui_redis_editor:col(dui_redis_editor:home(Ed0))),
    ?assertEqual(4, dui_redis_editor:col(dui_redis_editor:'end'(Ed0))).

roundtrip_test() ->
    Value = <<"line1\nline2\nline3">>,
    ?assertEqual(Value, dui_redis_editor:value(dui_redis_editor:new(Value))).
