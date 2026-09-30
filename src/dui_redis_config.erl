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
    next_id/1,
    list_favorites/2,
    add_favorite/4,
    remove_favorite/3,
    is_favorite/3,
    list_recent/2,
    add_recent/4,
    clear_recent/2,
    list_templates/1,
    add_template/2,
    delete_template/2,
    default_templates/0
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
      templates => default_templates(),
      tree_separator => <<":">>,
      max_recent_keys => 20,
      max_value_history => 50,
      watch_interval_ms => 1000}.

%% @doc Built-in key templates (mirrors redis-tui).
-spec default_templates() -> [map()].
default_templates() ->
    [#{name => <<"Session">>, description => <<"User session data">>,
       key_pattern => <<"session:{user_id}">>, type => <<"hash">>,
       default_ttl => 86400, default_value => <<>>,
       fields => #{token => <<>>, created_at => <<>>, user_agent => <<>>}},
     #{name => <<"Cache">>, description => <<"Cached data with TTL">>,
       key_pattern => <<"cache:{resource}:{id}">>, type => <<"string">>,
       default_ttl => 3600, default_value => <<>>, fields => #{}},
     #{name => <<"Rate Limit">>, description => <<"Rate limiting counter">>,
       key_pattern => <<"ratelimit:{ip}:{endpoint}">>, type => <<"string">>,
       default_ttl => 60, default_value => <<"0">>, fields => #{}},
     #{name => <<"Queue">>, description => <<"Job queue">>,
       key_pattern => <<"queue:{name}">>, type => <<"list">>,
       default_ttl => 0, default_value => <<>>, fields => #{}},
     #{name => <<"Leaderboard">>, description => <<"Sorted leaderboard">>,
       key_pattern => <<"leaderboard:{game}">>, type => <<"zset">>,
       default_ttl => 0, default_value => <<>>, fields => #{}}].

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
%% Favorites / recent keys / templates
%% ---------------------------------------------------------------------------

%% @doc Lists favorites for a connection, newest first.
-spec list_favorites(string(), integer()) -> {ok, [map()]} | {error, term()}.
list_favorites(Path, ConnId) ->
    with_config(Path, fun(Config) ->
        Favs = [F || F <- maps:get(favorites, Config, []),
                     maps:get(connection_id, F, 0) =:= ConnId],
        {ok, lists:sort(fun(A, B) ->
                            maps:get(added_at, A, <<>>) >= maps:get(added_at, B, <<>>)
                        end, Favs)}
    end).

%% @doc Adds a favorite (idempotent).
-spec add_favorite(string(), integer(), binary(), binary()) ->
    {ok, map()} | {error, term()}.
add_favorite(Path, ConnId, Key, Label) ->
    with_config(Path, fun(Config) ->
        Favs = maps:get(favorites, Config, []),
        case [F || F <- Favs,
                   maps:get(connection_id, F, 0) =:= ConnId,
                   maps:get(key, F, undefined) =:= Key] of
            [Existing | _] ->
                {ok, Existing};
            [] ->
                Fav = #{connection_id => ConnId, key => Key, label => Label,
                        added_at => now_iso8601()},
                case save(Path, Config#{favorites => Favs ++ [Fav]}) of
                    ok -> {ok, Fav};
                    {error, _} = Error -> Error
                end
        end
    end).

%% @doc Removes a favorite.
-spec remove_favorite(string(), integer(), binary()) -> ok | {error, term()}.
remove_favorite(Path, ConnId, Key) ->
    with_config(Path, fun(Config) ->
        Favs = maps:get(favorites, Config, []),
        New = [F || F <- Favs,
                    not (maps:get(connection_id, F, 0) =:= ConnId
                         andalso maps:get(key, F, undefined) =:= Key)],
        save(Path, Config#{favorites => New})
    end).

%% @doc True if a key is favorited for the connection.
-spec is_favorite(string(), integer(), binary()) -> boolean().
is_favorite(Path, ConnId, Key) ->
    case list_favorites(Path, ConnId) of
        {ok, Favs} -> lists:any(fun(F) -> maps:get(key, F, undefined) =:= Key end, Favs);
        _ -> false
    end.

%% @doc Lists recent keys for a connection (newest first).
-spec list_recent(string(), integer()) -> {ok, [map()]} | {error, term()}.
list_recent(Path, ConnId) ->
    with_config(Path, fun(Config) ->
        Recent = [R || R <- maps:get(recent_keys, Config, []),
                       maps:get(connection_id, R, 0) =:= ConnId],
        {ok, Recent}
    end).

%% @doc Records a recently accessed key (deduplicated, trimmed).
-spec add_recent(string(), integer(), binary(), binary()) -> ok | {error, term()}.
add_recent(Path, ConnId, Key, Type) ->
    with_config(Path, fun(Config) ->
        Recent = maps:get(recent_keys, Config, []),
        Without = [R || R <- Recent,
                        not (maps:get(connection_id, R, 0) =:= ConnId
                             andalso maps:get(key, R, undefined) =:= Key)],
        Entry = #{connection_id => ConnId, key => Key, type => Type,
                  accessed_at => now_iso8601()},
        Max = maps:get(max_recent_keys, Config, 20),
        New = lists:sublist([Entry | Without], Max),
        save(Path, Config#{recent_keys => New})
    end).

%% @doc Clears recent keys for a connection.
-spec clear_recent(string(), integer()) -> ok | {error, term()}.
clear_recent(Path, ConnId) ->
    with_config(Path, fun(Config) ->
        Recent = maps:get(recent_keys, Config, []),
        New = [R || R <- Recent, maps:get(connection_id, R, 0) =/= ConnId],
        save(Path, Config#{recent_keys => New})
    end).

%% @doc Lists key templates.
-spec list_templates(string()) -> {ok, [map()]} | {error, term()}.
list_templates(Path) ->
    with_config(Path, fun(Config) -> {ok, maps:get(templates, Config, [])} end).

%% @doc Adds a key template.
-spec add_template(string(), map()) -> ok | {error, term()}.
add_template(Path, Template) ->
    with_config(Path, fun(Config) ->
        Templates = maps:get(templates, Config, []),
        save(Path, Config#{templates => Templates ++ [Template]})
    end).

%% @doc Deletes a key template by name.
-spec delete_template(string(), binary()) -> ok | {error, term()}.
delete_template(Path, Name) ->
    with_config(Path, fun(Config) ->
        Templates = maps:get(templates, Config, []),
        New = [T || T <- Templates, maps:get(name, T, undefined) =/= Name],
        save(Path, Config#{templates => New})
    end).

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
       favorites => [normalize_favorite(F) || F <- list_value(<<"favorites">>, Data, [])],
       recent_keys => [normalize_recent(R) || R <- list_value(<<"recent_keys">>, Data, [])],
       templates => normalize_templates(value(<<"templates">>, Data, undefined)),
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

-spec normalize_templates(term()) -> [map()].
normalize_templates(undefined) -> default_templates();
normalize_templates(List) when is_list(List) -> [normalize_template(T) || T <- List];
normalize_templates(_Other) -> default_templates().

-spec normalize_favorite(term()) -> map().
normalize_favorite(F) when is_map(F) ->
    #{connection_id => value(<<"connection_id">>, F, 0),
      connection => value(<<"connection">>, F, <<>>),
      key => value(<<"key">>, F, <<>>),
      label => value(<<"label">>, F, <<>>),
      added_at => value(<<"added_at">>, F, <<>>)};
normalize_favorite(_F) ->
    #{}.

-spec normalize_recent(term()) -> map().
normalize_recent(R) when is_map(R) ->
    #{connection_id => value(<<"connection_id">>, R, 0),
      key => value(<<"key">>, R, <<>>),
      type => value(<<"type">>, R, <<"string">>),
      accessed_at => value(<<"accessed_at">>, R, <<>>)};
normalize_recent(_R) ->
    #{}.

-spec normalize_template(term()) -> map().
normalize_template(T) when is_map(T) ->
    #{name => value(<<"name">>, T, <<>>),
      description => value(<<"description">>, T, <<>>),
      key_pattern => value(<<"key_pattern">>, T, value(<<"pattern">>, T, <<>>)),
      type => value(<<"type">>, T, value(<<"key_type">>, T, <<"string">>)),
      default_ttl => value(<<"default_ttl">>, T, 0),
      default_value => value(<<"default_value">>, T, <<>>),
      fields => value(<<"fields">>, T, #{})};
normalize_template(_T) ->
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
