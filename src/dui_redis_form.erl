%% @doc Connection add/edit form model (pure).
%%
%% The form is a plain map held in `#dui_state.conn_form{}' and mutated by
%% pure functions, so it is easy to unit test. Text editing reuses
%% `educkui_lineedit' (grapheme-aware).
-module(dui_redis_form).

-export([
    new_add/0,
    new_edit/1,
    fields/0,
    mode/1,
    id/1,
    focus/1,
    error/1,
    values/1,
    value/2,
    cursor/1,
    focused_field/1,
    insert/2,
    backspace/1,
    delete/1,
    move/2,
    home/1,
    'end'/1,
    focus_next/1,
    focus_prev/1,
    toggle/1,
    set_error/2,
    clear_error/1,
    validate/1,
    to_connection/1
]).

-type form() :: map().
-export_type([form/0]).

%% ---------------------------------------------------------------------------
%% Construction
%% ---------------------------------------------------------------------------

%% @doc Creates an empty "add connection" form.
-spec new_add() -> form().
new_add() ->
    build(add, undefined, undefined).

%% @doc Creates an "edit connection" form populated from `Conn'.
-spec new_edit(map()) -> form().
new_edit(Conn) ->
    build(edit, maps:get(id, Conn, undefined), Conn).

-spec build(add | edit, integer() | undefined, map() | undefined) -> form().
build(Mode, Id, Conn) ->
    Values = initial_values(Conn),
    #{mode => Mode,
      id => Id,
      values => Values,
      focus => 0,
      cursor => cursor_for_value(maps:get(host, Values, <<"localhost">>)),
      error => undefined}.

%% ---------------------------------------------------------------------------
%% Accessors
%% ---------------------------------------------------------------------------

%% @doc Ordered field specifications.
-spec fields() -> [map()].
fields() ->
    [#{id => name, label => <<"Name">>, type => text},
     #{id => host, label => <<"Host">>, type => text},
     #{id => port, label => <<"Port">>, type => text},
     #{id => username, label => <<"Username">>, type => text},
     #{id => password, label => <<"Password">>, type => password},
     #{id => cluster, label => <<"Cluster Mode">>, type => bool},
     #{id => db, label => <<"Database">>, type => text}].

-spec mode(form()) -> add | edit.
mode(#{mode := Mode}) -> Mode.

-spec id(form()) -> integer() | undefined.
id(#{id := Id}) -> Id.

-spec focus(form()) -> non_neg_integer().
focus(#{focus := Focus}) -> Focus.

-spec error(form()) -> binary() | undefined.
error(#{error := Error}) -> Error.

-spec values(form()) -> map().
values(#{values := Values}) -> Values.

-spec value(form(), atom()) -> term().
value(#{values := Values}, FieldId) -> maps:get(FieldId, Values, undefined).

-spec cursor(form()) -> non_neg_integer().
cursor(#{cursor := Cursor}) -> Cursor.

-spec focused_field(form()) -> map().
focused_field(#{focus := Focus}) ->
    lists:nth(Focus + 1, fields()).

%% ---------------------------------------------------------------------------
%% Editing
%% ---------------------------------------------------------------------------

-spec insert(binary(), form()) -> form().
insert(Char, Form) ->
    case field_type(Form) of
        bool -> Form;
        _ -> edit_focused(Form, fun(LE) -> educkui_lineedit:insert(Char, LE) end)
    end.

-spec backspace(form()) -> form().
backspace(Form) ->
    case field_type(Form) of
        bool -> Form;
        _ -> edit_focused(Form, fun educkui_lineedit:backspace/1)
    end.

-spec delete(form()) -> form().
delete(Form) ->
    case field_type(Form) of
        bool -> Form;
        _ -> edit_focused(Form, fun educkui_lineedit:delete/1)
    end.

-spec move(left | right, form()) -> form().
move(Direction, Form) ->
    case field_type(Form) of
        bool -> Form;
        _ -> edit_focused(Form, fun(LE) -> educkui_lineedit:move(Direction, LE) end)
    end.

-spec home(form()) -> form().
home(Form) ->
    case field_type(Form) of
        bool -> Form;
        _ -> edit_focused(Form, fun educkui_lineedit:home/1)
    end.

-spec 'end'(form()) -> form().
'end'(Form) ->
    case field_type(Form) of
        bool -> Form;
        _ -> edit_focused(Form, fun educkui_lineedit:'end'/1)
    end.

%% ---------------------------------------------------------------------------
%% Focus / toggles
%% ---------------------------------------------------------------------------

-spec focus_next(form()) -> form().
focus_next(Form) ->
    set_focus(Form, (focus(Form) + 1) rem length(fields())).

-spec focus_prev(form()) -> form().
focus_prev(Form) ->
    Count = length(fields()),
    set_focus(Form, (focus(Form) - 1 + Count) rem Count).

-spec toggle(form()) -> form().
toggle(Form) ->
    case field_type(Form) of
        bool ->
            FieldId = field_id(Form),
            Values = values(Form),
            Form#{values := Values#{FieldId => not maps:get(FieldId, Values, false)}};
        _ ->
            Form
    end.

-spec set_error(binary() | undefined, form()) -> form().
set_error(Error, Form) ->
    Form#{error := Error}.

-spec clear_error(form()) -> form().
clear_error(Form) ->
    Form#{error := undefined}.

%% ---------------------------------------------------------------------------
%% Validation / conversion
%% ---------------------------------------------------------------------------

%% @doc Validates required fields. Returns `ok' or `{error, Message}'.
-spec validate(form()) -> ok | {error, binary()}.
validate(Form) ->
    V = values(Form),
    Name = maps:get(name, V, <<>>),
    Host = maps:get(host, V, <<>>),
    case Name of
        <<>> -> {error, <<"Name is required">>};
        _ ->
            case Host of
                <<>> -> {error, <<"Host is required">>};
                _ -> validate_port(V)
            end
    end.

-spec validate_port(map()) -> ok | {error, binary()}.
validate_port(V) ->
    case parse_int(maps:get(port, V, <<>>)) of
        {ok, Port} when Port > 0 -> ok;
        _ -> {error, <<"Port must be a positive integer">>}
    end.

%% @doc Converts the form to a connection map.
-spec to_connection(form()) -> map().
to_connection(Form) ->
    V = values(Form),
    #{id => id(Form),
      name => maps:get(name, V, <<>>),
      host => maps:get(host, V, <<>>),
      port => int_or(maps:get(port, V, <<>>), 6379),
      username => maps:get(username, V, <<>>),
      password => maps:get(password, V, <<>>),
      db => int_or(maps:get(db, V, <<>>), 0),
      use_cluster => maps:get(cluster, V, false),
      use_tls => false}.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

-spec field_type(form()) -> text | password | bool.
field_type(Form) ->
    maps:get(type, focused_field(Form)).

-spec field_id(form()) -> atom().
field_id(Form) ->
    maps:get(id, focused_field(Form)).

-spec set_focus(form(), non_neg_integer()) -> form().
set_focus(Form, Focus) ->
    Values = values(Form),
    Field = lists:nth(Focus + 1, fields()),
    Form#{focus := Focus,
          cursor := cursor_for(Values, Field),
          error := undefined}.

-spec cursor_for(map(), map()) -> non_neg_integer().
cursor_for(_Values, #{type := bool}) ->
    0;
cursor_for(Values, #{id := FieldId}) ->
    cursor_for_value(maps:get(FieldId, Values, <<>>)).

-spec cursor_for_value(term()) -> non_neg_integer().
cursor_for_value(Value) when is_binary(Value) -> string:length(Value);
cursor_for_value(_) -> 0.

-spec edit_focused(form(), fun((educkui_lineedit:state()) -> educkui_lineedit:state())) ->
    form().
edit_focused(Form, Fun) ->
    FieldId = field_id(Form),
    Values = values(Form),
    LE1 = Fun(educkui_lineedit:new(maps:get(FieldId, Values, <<>>), cursor(Form))),
    Form#{values := Values#{FieldId => educkui_lineedit:value(LE1)},
          cursor := educkui_lineedit:cursor(LE1),
          error := undefined}.

-spec initial_values(map() | undefined) -> map().
initial_values(undefined) ->
    #{name => <<>>, host => <<"localhost">>, port => <<"6379">>,
      username => <<>>, password => <<>>, cluster => false, db => <<"0">>};
initial_values(Conn) ->
    #{name => to_bin(maps:get(name, Conn, <<>>)),
      host => to_bin(maps:get(host, Conn, <<"localhost">>)),
      port => integer_to_binary(maps:get(port, Conn, 6379)),
      username => to_bin(maps:get(username, Conn, <<>>)),
      password => to_bin(maps:get(password, Conn, <<>>)),
      cluster => maps:get(use_cluster, Conn, false),
      db => integer_to_binary(maps:get(db, Conn, 0))}.

-spec parse_int(term()) -> {ok, integer()} | error.
parse_int(Bin) when is_binary(Bin) ->
    try {ok, binary_to_integer(string:trim(Bin))}
    catch error:badarg -> error
    end;
parse_int(Int) when is_integer(Int) ->
    {ok, Int};
parse_int(_) ->
    error.

-spec int_or(term(), integer()) -> integer().
int_or(Value, Default) ->
    case parse_int(Value) of
        {ok, Int} -> Int;
        error -> Default
    end.

-spec to_bin(term()) -> binary().
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(undefined) -> <<>>;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).
