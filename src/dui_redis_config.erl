%% @doc Configuration persistence.
%%
%% Loads/saves `~/.config/dui-redis/config.json' using OTP's built-in `json'
%% module. Secrets (passwords, SSH passphrases) are stripped before writing,
%% and the file is written with `0600' permissions via a temp-file rename.
%%
%% The schema is intentionally compatible with redis-tui's config file so
%% existing data can be reused.
-module(dui_redis_config).

-export([
    path/0,
    load/0, load/1,
    save/1, save/2,
    defaults/0,
    strip_secrets/1,
    list_connections/1,
    add_connection/2,
    update_connection/2,
    delete_connection/2,
    normalize_connection/1,
    next_id/1
]).

-define(DIR, ".config/dui-redis").
-define(CONFIG_FILE, "config.json").

%% @doc Default config path (`$HOME/.config/dui-redis/config.json').
-spec path() -> string().
path() ->
    filename:join([home_dir(), ?DIR, ?CONFIG_FILE]).

%% @doc Loads the default config path.
-spec load() -> {ok, map()} | {error, term()}.
load() ->
    load(path()).

%% @doc Loads config from `Path'. Missing files yield `defaults/0'.
-spec load(string() | binary()) -> {ok, map()} | {error, term()}.
load(Path0) ->
    Path = to_path(Path0),
    case file:read_file(Path) of
        {ok, Bin} ->
            try json:decode(Bin) of
                Data -> {ok, normalize(Data)}
            catch
                _:_ -> {error, {invalid_config, Path}}
            end;
        {error, enoent} ->
            {ok, defaults()};
        {error, Reason} ->
            {error, {read_failed, Path, Reason}}
    end.

%% @doc Saves to the default config path.
-spec save(map()) -> ok | {error, term()}.
save(Config) ->
    save(path(), Config).

%% @doc Saves `Config' to `Path' atomically.
-spec save(string(), map()) -> ok | {error, term()}.
save(Path0, Config) ->
    Path = to_path(Path0),
    Safe = strip_secrets(Config),
    Binary = iolist_to_binary(json:encode(Safe)),
    Tmp = Path ++ ".tmp",
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Tmp, Binary) of
                ok ->
                    _ = file:change_mode(Tmp, 8#600),
                    file:rename(Tmp, Path);
                {error, Reason} ->
                    {error, {write_failed, Tmp, Reason}}
            end;
        {error, Reason} ->
            {error, {mkdir_failed, filename:dirname(Path), Reason}}
    end.

-spec to_path(binary() | string()) -> string().
to_path(Path) when is_binary(Path) -> binary_to_list(Path);
to_path(Path) when is_list(Path) -> Path.

%% @doc Default configuration.
-spec defaults() -> map().
defaults() ->
    #{connections => [],
      favorites => [],
      recent_keys => [],
      templates => [],
      tree_separator => <<":">>,
      max_recent_keys => 20,
      max_value_history => 50,
      watch_interval_ms => 1000}.

%% @doc Removes secrets from a config map before persistence.
-spec strip_secrets(map()) -> map().
strip_secrets(Config) when is_map(Config) ->
    Connections = maps:get(connections, Config, []),
    Config#{connections => [strip_connection(C) || C <- Connections]};
strip_secrets(Config) ->
    Config.

%% ---------------------------------------------------------------------------
%% Connection CRUD
%% ---------------------------------------------------------------------------

%% @doc Returns the saved connections, sorted by id.
-spec list_connections(string()) -> {ok, [map()]} | {error, term()}.
list_connections(Path) ->
    case load(Path) of
        {ok, Config} ->
            Conns = maps:get(connections, Config, []),
            {ok, lists:sort(fun(A, B) -> maps:get(id, A, 0) =< maps:get(id, B, 0) end,
                            Conns)};
        {error, _} = Error ->
            Error
    end.

%% @doc Adds a connection, assigning a new id and timestamps.
-spec add_connection(string(), map()) -> {ok, map()} | {error, term()}.
add_connection(Path, Conn0) ->
    with_config(Path, fun(Config) ->
        Conns = maps:get(connections, Config, []),
        Id = next_id(Conns),
        Now = now_iso8601(),
        Conn = normalize_connection(
            Conn0#{id => Id, created_at => Now, updated_at => Now}),
        case save(Path, Config#{connections => Conns ++ [Conn]}) of
            ok -> {ok, Conn};
            {error, _} = Error -> Error
        end
    end).

%% @doc Updates the connection with the same id.
-spec update_connection(string(), map()) -> {ok, map()} | {error, term()}.
update_connection(Path, Conn0) ->
    Id = maps:get(id, Conn0, undefined),
    with_config(Path, fun(Config) ->
        Conns = maps:get(connections, Config, []),
        case replace_connection(Id, Conn0, Conns) of
            {ok, NewConns, Updated} ->
                case save(Path, Config#{connections => NewConns}) of
                    ok -> {ok, Updated};
                    {error, _} = Error -> Error
                end;
            error ->
                {error, not_found}
        end
    end).

%% @doc Deletes the connection with `Id'.
-spec delete_connection(string(), integer()) -> ok | {error, term()}.
delete_connection(Path, Id) ->
    with_config(Path, fun(Config) ->
        Conns = maps:get(connections, Config, []),
        NewConns = [C || C <- Conns, maps:get(id, C, undefined) =/= Id],
        case length(NewConns) =:= length(Conns) of
            true ->
                {error, not_found};
            false ->
                case save(Path, Config#{connections => NewConns}) of
                    ok -> ok;
                    {error, _} = Error -> Error
                end
        end
    end).

%% @doc Returns the next available connection id.
-spec next_id([map()]) -> pos_integer().
next_id(Conns) ->
    Max = lists:max([maps:get(id, C, 0) || C <- Conns] ++ [0]),
    Max + 1.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

-spec strip_connection(map()) -> map().
strip_connection(Conn) when is_map(Conn) ->
    maps:remove(password, Conn);
strip_connection(Conn) ->
    Conn.

-spec normalize(term()) -> map().
normalize(Data) when is_map(Data) ->
    D = defaults(),
    D#{connections => [normalize_connection(C)
                        || C <- list_value(<<"connections">>, Data, [])],
       favorites => list_value(<<"favorites">>, Data, []),
       recent_keys => list_value(<<"recent_keys">>, Data, []),
       templates => list_value(<<"templates">>, Data, []),
       tree_separator => value(<<"tree_separator">>, Data, <<":">>),
       max_recent_keys => value(<<"max_recent_keys">>, Data, 20),
       max_value_history => value(<<"max_value_history">>, Data, 50),
       watch_interval_ms => value(<<"watch_interval_ms">>, Data, 1000)};
normalize(_Data) ->
    defaults().

-spec normalize_connection(term()) -> map().
normalize_connection(C) when is_map(C) ->
    #{id => value(<<"id">>, C, 0),
      name => value(<<"name">>, C, <<>>),
      host => value(<<"host">>, C, <<>>),
      port => value(<<"port">>, C, 6379),
      username => value(<<"username">>, C, <<>>),
      password => value(<<"password">>, C, <<>>),
      vault_path => value(<<"vault_path">>, C, <<>>),
      vault_username_key => value(<<"vault_username_key">>, C, <<>>),
      vault_password_key => value(<<"vault_password_key">>, C, <<>>),
      db => value(<<"db">>, C, 0),
      use_cluster => value(<<"use_cluster">>, C, false),
      use_tls => value(<<"use_tls">>, C, false),
      tls_config => value(<<"tls_config">>, C, undefined),
      created_at => value(<<"created_at">>, C, undefined),
      updated_at => value(<<"updated_at">>, C, undefined)};
normalize_connection(_C) ->
    #{}.

%% Reads a value by binary key, falling back to the atom key (in-code configs).
-spec value(binary(), map(), term()) -> term().
value(Key, Data, Default) ->
    case maps:find(Key, Data) of
        {ok, Value} ->
            Value;
        error ->
            case atom_key(Key) of
                undefined -> Default;
                Atom -> maps:get(Atom, Data, Default)
            end
    end.

-spec list_value(binary(), map(), [term()]) -> [term()].
list_value(Key, Data, Default) ->
    case value(Key, Data, Default) of
        L when is_list(L) -> L;
        _ -> Default
    end.

-spec atom_key(binary()) -> atom() | undefined.
atom_key(Key) ->
    try binary_to_existing_atom(Key, utf8)
    catch
        error:badarg -> undefined
    end.

-spec home_dir() -> string().
home_dir() ->
    case os:getenv("HOME") of
        false -> ".";
        "" -> ".";
        Home -> Home
    end.

-spec with_config(string(), fun((map()) -> T)) -> T | {error, term()}.
with_config(Path, Fun) ->
    case load(Path) of
        {ok, Config} -> Fun(Config);
        {error, _} = Error -> Error
    end.

-spec replace_connection(integer(), map(), [map()]) ->
    {ok, [map()], map()} | error.
replace_connection(Id, Conn0, Conns) ->
    case lists:search(fun(C) -> maps:get(id, C, undefined) =:= Id end, Conns) of
        {value, Existing} ->
            Now = now_iso8601(),
            Created = maps:get(created_at, Existing, Now),
            Updated = normalize_connection(
                Conn0#{id => Id, created_at => Created, updated_at => Now}),
            NewConns = [case maps:get(id, C, undefined) =:= Id of
                            true -> Updated;
                            false -> C
                        end || C <- Conns],
            {ok, NewConns, Updated};
        false ->
            error
    end.

-spec now_iso8601() -> binary().
now_iso8601() ->
    iolist_to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}])).
