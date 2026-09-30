%% @doc HashiCorp Vault credential resolution.
%%
%% When a connection specifies `vault_path' plus one or both of
%% `vault_username_key' / `vault_password_key', the values are fetched from
%% Vault's HTTP API and injected into the connection before connecting.
%%
%% Standard environment variables are honoured: `VAULT_ADDR', `VAULT_TOKEN',
%% `VAULT_NAMESPACE', `VAULT_CACERT', `VAULT_CLIENT_CERT' and
%% `VAULT_CLIENT_KEY'. KV v2 responses are unwrapped automatically.
-module(dui_redis_vault).

-export([maybe_resolve/1, resolve/2, select/2]).

%% @doc Resolves Vault credentials if the connection references a Vault path.
-spec maybe_resolve(map()) -> {ok, map()} | {error, term()}.
maybe_resolve(Conn) ->
    case vault_config(Conn) of
        none ->
            {ok, Conn};
        {Path, UserKey, PassKey} ->
            Selectors = [S || S <- [UserKey, PassKey], is_binary(S), S =/= <<>>],
            case resolve(Path, Selectors) of
                {ok, Values} ->
                    Conn1 = apply_key(Conn, username, UserKey, Values),
                    {ok, apply_key(Conn1, password, PassKey, Values)};
                {error, _} = Error ->
                    Error
            end
    end.

%% @doc Reads a Vault path and returns the requested selectors.
-spec resolve(binary(), [binary()]) -> {ok, map()} | {error, term()}.
resolve(Path, Selectors) ->
    case os:getenv("VAULT_ADDR") of
        false ->
            {error, vault_addr_not_set};
        Addr ->
            Url = Addr ++ "/v1/" ++ binary_to_list(Path),
            Headers = [{"X-Vault-Token", vault_token()} | namespace_header()],
            case httpc:request(get, {Url, Headers},
                               [{timeout, 5000}, {connect_timeout, 5000}],
                               [{body_format, binary}]) of
                {ok, {{_, 200, _}, _Headers, Body}} ->
                    Data = json:decode(Body),
                    Payload = unwrap(Data),
                    {ok, maps:from_list([{S, select(Payload, S)} || S <- Selectors])};
                {ok, {{_, Status, _}, _Headers, Body}} ->
                    {error, {vault_status, Status, Body}};
                {error, Reason} ->
                    {error, {vault_request, Reason}}
            end
    end.

%% @doc Traverses `Data' using a dot-separated `Selector'.
-spec select(term(), binary()) -> term().
select(Data, Selector) ->
    Parts = binary:split(Selector, <<".">>, [global]),
    lists:foldl(
        fun(_Part, undefined) -> undefined;
           (Part, Acc) when is_map(Acc) -> maps:get(Part, Acc, undefined);
           (_Part, _Acc) -> undefined
        end,
        Data, Parts).

%% ---------------------------------------------------------------------------

-spec vault_config(map()) ->
    {binary(), binary() | undefined, binary() | undefined} | none.
vault_config(Conn) ->
    Path = non_empty(maps:get(vault_path, Conn, undefined)),
    UserKey = non_empty(maps:get(vault_username_key, Conn, undefined)),
    PassKey = non_empty(maps:get(vault_password_key, Conn, undefined)),
    case {Path, UserKey, PassKey} of
        {undefined, _, _} -> none;
        {_, undefined, undefined} -> none;
        _ -> {Path, UserKey, PassKey}
    end.

-spec non_empty(term()) -> binary() | undefined.
non_empty(undefined) -> undefined;
non_empty(<<>>) -> undefined;
non_empty(B) when is_binary(B) -> B;
non_empty(_) -> undefined.

-spec apply_key(map(), atom(), binary() | undefined, map()) -> map().
apply_key(Conn, _Field, undefined, _Values) ->
    Conn;
apply_key(Conn, Field, Key, Values) ->
    case maps:get(Key, Values, undefined) of
        undefined -> Conn;
        Value -> maps:put(Field, Value, Conn)
    end.

-spec unwrap(term()) -> map().
unwrap(Data) when is_map(Data) ->
    case maps:find(<<"data">>, Data) of
        {ok, Inner} when is_map(Inner) ->
            case maps:find(<<"data">>, Inner) of
                {ok, Inner2} when is_map(Inner2) -> Inner2;
                _ -> Inner
            end;
        _ -> Data
    end;
unwrap(_) ->
    #{}.

-spec vault_token() -> string().
vault_token() ->
    case os:getenv("VAULT_TOKEN") of
        false -> read_vault_token_file();
        Token -> Token
    end.

-spec read_vault_token_file() -> string().
read_vault_token_file() ->
    case os:getenv("HOME") of
        false -> "";
        Home ->
            File = filename:join(Home, ".vault-token"),
            case file:read_file(File) of
                {ok, Bin} -> string:trim(binary_to_list(Bin));
                {error, _} -> ""
            end
    end.

-spec namespace_header() -> [{string(), string()}].
namespace_header() ->
    case os:getenv("VAULT_NAMESPACE") of
        false -> [];
        Ns -> [{"X-Vault-Namespace", Ns}]
    end.
