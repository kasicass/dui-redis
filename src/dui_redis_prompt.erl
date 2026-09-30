%% @doc Pure multi-field text prompt model.
%%
%% A generalisation of the connection form for small "fill in and submit"
%% dialogs: add/remove collection members, rename, copy, TTL, Lua scripts.
%% Fields are `{Id, Label, Masked}' tuples; text editing reuses
%% `educkui_lineedit'.
-module(dui_redis_prompt).

-export([
    new/1, new/2,
    fields/1,
    focus/1,
    cursor/1,
    value/2,
    set_value/3,
    values/1,
    focused_field/1,
    insert/2,
    backspace/1,
    delete/1,
    move/2,
    home/1,
    'end'/1,
    focus_next/1,
    focus_prev/1,
    to_map/1
]).

-type field() :: {atom(), binary(), boolean()}.
-type prompt() :: map().
-export_type([field/0, prompt/0]).

%% ---------------------------------------------------------------------------

%% @doc Creates a prompt with the given fields (empty defaults).
-spec new([field()]) -> prompt().
new(Fields) -> new(Fields, #{}).

%% @doc Creates a prompt with initial values from `Defaults' (by field id).
-spec new([field()], map()) -> prompt().
new(Fields, Defaults) ->
    Values = maps:from_list(
        [{Id, maps:get(Id, Defaults, <<>>)} || {Id, _Label, _Masked} <- Fields]),
    Cursor = case Fields of
        [{FirstId, _, _} | _] -> string:length(maps:get(FirstId, Values, <<>>));
        [] -> 0
    end,
    #{fields => Fields, values => Values, focus => 0, cursor => Cursor}.

-spec fields(prompt()) -> [field()].
fields(#{fields := Fields}) -> Fields.

-spec focus(prompt()) -> non_neg_integer().
focus(#{focus := Focus}) -> Focus.

-spec cursor(prompt()) -> non_neg_integer().
cursor(#{cursor := Cursor}) -> Cursor.

-spec value(prompt(), atom()) -> binary().
value(#{values := Values}, Id) -> maps:get(Id, Values, <<>>).

-spec set_value(prompt(), atom(), binary()) -> prompt().
set_value(#{values := Values} = P, Id, Value) ->
    P#{values := Values#{Id => Value}}.

-spec values(prompt()) -> map().
values(#{values := Values}) -> Values.

-spec focused_field(prompt()) -> field().
focused_field(#{focus := Focus, fields := Fields}) ->
    lists:nth(Focus + 1, Fields).

%% ---------------------------------------------------------------------------

-spec insert(binary(), prompt()) -> prompt().
insert(Text, P) -> edit(P, fun(LE) -> educkui_lineedit:insert(Text, LE) end).

-spec backspace(prompt()) -> prompt().
backspace(P) -> edit(P, fun educkui_lineedit:backspace/1).

-spec delete(prompt()) -> prompt().
delete(P) -> edit(P, fun educkui_lineedit:delete/1).

-spec move(left | right, prompt()) -> prompt().
move(Dir, P) -> edit(P, fun(LE) -> educkui_lineedit:move(Dir, LE) end).

-spec home(prompt()) -> prompt().
home(P) -> edit(P, fun educkui_lineedit:home/1).

-spec 'end'(prompt()) -> prompt().
'end'(P) -> edit(P, fun educkui_lineedit:'end'/1).

-spec focus_next(prompt()) -> prompt().
focus_next(P) ->
    set_focus(P, (focus(P) + 1) rem length(fields(P))).

-spec focus_prev(prompt()) -> prompt().
focus_prev(P) ->
    Count = length(fields(P)),
    set_focus(P, (focus(P) - 1 + Count) rem Count).

-spec to_map(prompt()) -> map().
to_map(P) ->
    maps:from_list(
        [{Id, value(P, Id)} || {Id, _, _} <- fields(P)]).

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

-spec edit(prompt(), fun((educkui_lineedit:state()) -> educkui_lineedit:state())) ->
    prompt().
edit(P, Fun) ->
    {Id, _Label, _Masked} = focused_field(P),
    LE1 = Fun(educkui_lineedit:new(value(P, Id), cursor(P))),
    set_value(P#{cursor := educkui_lineedit:cursor(LE1)}, Id,
              educkui_lineedit:value(LE1)).

-spec set_focus(prompt(), non_neg_integer()) -> prompt().
set_focus(P, Focus) ->
    Field = lists:nth(Focus + 1, fields(P)),
    {Id, _Label, _Masked} = Field,
    P#{focus := Focus, cursor := string:length(value(P, Id))}.
