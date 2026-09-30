%% @doc Pure multi-line text editor model.
%%
%% Stores a value as a list of lines plus a `{row, col}' cursor (both in
%% grapheme counts). Used by the string/JSON value editor and the Lua script
%% screen. No processes, no rendering.
-module(dui_redis_editor).

-export([
    new/0, new/1,
    value/1,
    lines/1,
    row/1,
    col/1,
    line_count/1,
    insert/2,
    newline/1,
    backspace/1,
    delete/1,
    move/2,
    home/1,
    'end'/1,
    set_cursor/3
]).

-type editor() :: map().
-export_type([editor/0]).

%% ---------------------------------------------------------------------------

-spec new() -> editor().
new() -> new(<<>>).

-spec new(binary()) -> editor().
new(Value) when is_binary(Value) ->
    Lines = binary:split(Value, <<"\n">>, [global]),
    #{lines => Lines, row => 0, col => 0}.

-spec value(editor()) -> binary().
value(#{lines := Lines}) ->
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

-spec lines(editor()) -> [binary()].
lines(#{lines := Lines}) -> Lines.

-spec row(editor()) -> non_neg_integer().
row(#{row := Row}) -> Row.

-spec col(editor()) -> non_neg_integer().
col(#{col := Col}) -> Col.

-spec line_count(editor()) -> pos_integer().
line_count(#{lines := Lines}) -> length(Lines).

%% ---------------------------------------------------------------------------

-spec insert(binary(), editor()) -> editor().
insert(Text, Ed) ->
    LE = lineedit(Ed),
    LE1 = educkui_lineedit:insert(Text, LE),
    set_line(Ed, educkui_lineedit:value(LE1), educkui_lineedit:cursor(LE1)).

-spec newline(editor()) -> editor().
newline(Ed) ->
    Line = current_line(Ed),
    {Left, Right} = split_at(Line, col(Ed)),
    Lines = lines(Ed),
    Row = row(Ed),
    Lines1 = replace_nth(Row, Left, Lines),
    Lines2 = insert_after(Row, Right, Lines1),
    Ed#{lines := Lines2, row := Row + 1, col := 0}.

-spec backspace(editor()) -> editor().
backspace(Ed) ->
    case col(Ed) of
        0 ->
            case row(Ed) of
                0 -> Ed;
                Row ->
                    Prev = lists:nth(Row, lines(Ed)),  %% previous line (1-based)
                    Cur = current_line(Ed),
                    Lines1 = replace_nth(Row - 1, <<Prev/binary, Cur/binary>>, lines(Ed)),
                    Lines2 = remove_nth(Row, Lines1),
                    Ed#{lines := Lines2, row := Row - 1, col := string:length(Prev)}
            end;
        _ ->
            LE = educkui_lineedit:backspace(lineedit(Ed)),
            set_line(Ed, educkui_lineedit:value(LE), educkui_lineedit:cursor(LE))
    end.

-spec delete(editor()) -> editor().
delete(Ed) ->
    Line = current_line(Ed),
    case col(Ed) >= string:length(Line) of
        true ->
            merge_next(Ed);
        false ->
            LE = educkui_lineedit:delete(lineedit(Ed)),
            set_line(Ed, educkui_lineedit:value(LE), educkui_lineedit:cursor(LE))
    end.

-spec move(left | right | up | down, editor()) -> editor().
move(left, Ed) ->
    LE = educkui_lineedit:move(left, lineedit(Ed)),
    set_line(Ed, educkui_lineedit:value(LE), educkui_lineedit:cursor(LE));
move(right, Ed) ->
    LE = educkui_lineedit:move(right, lineedit(Ed)),
    set_line(Ed, educkui_lineedit:value(LE), educkui_lineedit:cursor(LE));
move(up, Ed) ->
    case row(Ed) of
        0 -> Ed;
        Row -> move_row(Ed, Row - 1)
    end;
move(down, Ed) ->
    Row = row(Ed),
    case Row + 1 < line_count(Ed) of
        true -> move_row(Ed, Row + 1);
        false -> Ed
    end.

-spec home(editor()) -> editor().
home(Ed) -> Ed#{col := 0}.

-spec 'end'(editor()) -> editor().
'end'(Ed) -> Ed#{col := string:length(current_line(Ed))}.

-spec set_cursor(non_neg_integer(), non_neg_integer(), editor()) -> editor().
set_cursor(Row, Col, Ed) ->
    Row1 = min(Row, line_count(Ed) - 1),
    Line = lists:nth(Row1 + 1, lines(Ed)),
    Ed#{row := Row1, col := min(Col, string:length(Line))}.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

-spec lineedit(editor()) -> educkui_lineedit:state().
lineedit(Ed) ->
    educkui_lineedit:new(current_line(Ed), col(Ed)).

-spec current_line(editor()) -> binary().
current_line(Ed) ->
    lists:nth(row(Ed) + 1, lines(Ed)).

-spec set_line(editor(), binary(), non_neg_integer()) -> editor().
set_line(Ed, Line, Col) ->
    Ed#{lines := replace_nth(row(Ed), Line, lines(Ed)), col := Col}.

-spec move_row(editor(), non_neg_integer()) -> editor().
move_row(Ed, Row) ->
    Line = lists:nth(Row + 1, lines(Ed)),
    Ed#{row := Row, col := min(col(Ed), string:length(Line))}.

-spec merge_next(editor()) -> editor().
merge_next(Ed) ->
    Row = row(Ed),
    case Row + 1 < line_count(Ed) of
        false ->
            Ed;
        true ->
            Cur = current_line(Ed),
            Next = lists:nth(Row + 2, lines(Ed)),
            Lines1 = replace_nth(Row, <<Cur/binary, Next/binary>>, lines(Ed)),
            Lines2 = remove_nth(Row + 1, Lines1),
            Ed#{lines := Lines2}
    end.

-spec split_at(binary(), non_neg_integer()) -> {binary(), binary()}.
split_at(Bin, N) ->
    {string:slice(Bin, 0, N), string:slice(Bin, N)}.

-spec replace_nth(non_neg_integer(), term(), [term()]) -> [term()].
replace_nth(Index, Value, List) ->
    {Before, [_ | After]} = lists:split(Index, List),
    Before ++ [Value | After].

-spec insert_after(non_neg_integer(), term(), [term()]) -> [term()].
insert_after(Index, Value, List) ->
    {Before, After} = lists:split(Index + 1, List),
    Before ++ [Value | After].

-spec remove_nth(non_neg_integer(), [term()]) -> [term()].
remove_nth(Index, List) ->
    {Before, [_ | After]} = lists:split(Index, List),
    Before ++ After.
