%% @doc CLI argument parsing built on OTP's `argparse'.
%%
%% Produces a normalized options map:
%%
%% ```
%% #{version := boolean(),
%%   update := boolean(),
%%   scan_size := integer(),
%%   include_types := boolean(),
%%   config_path := string() | undefined,
%%   connection => #{...} | undefined}
%% '''
%%
%% Short flags follow redis-cli conventions (`-h', `-p', `-a', `-n').
-module(dui_redis_cli).

-export([parse/1, spec/0, format_error/1]).

%% @doc Parses command line arguments. Returns `{ok, Opts}' or `{error, Reason}'.
-spec parse([string()]) -> {ok, map()} | {error, term()}.
parse(Args) ->
    try argparse:parse(Args, spec(), #{progname => "dui-redis"}) of
        {ok, ArgMap, _Path, _Command} -> {ok, normalize(ArgMap)};
        {error, Reason} -> {error, Reason}
    catch
        error:Reason -> {error, Reason}
    end.

%% @doc Formats a parser error for display.
-spec format_error(term()) -> unicode:chardata().
format_error(Reason) ->
    try argparse:format_error(Reason)
    catch _:_ -> io_lib:format("~p", [Reason])
    end.

%% @doc The argparse command specification.
-spec spec() -> argparse:command().
spec() ->
    #{
        arguments => [
            #{name => version, long => "-version", type => boolean, default => false},
            #{name => update, long => "-update", type => boolean, default => false},
            #{name => host, long => "-host", short => $h, type => string, default => undefined},
            #{name => port, long => "-port", short => $p, type => integer, default => 6379},
            #{name => password, long => "-password", short => $a, type => string, default => undefined},
            #{name => user, long => "-user", type => string, default => undefined},
            #{name => db, long => "-db", short => $n, type => integer, default => 0},
            #{name => name, long => "-name", type => string, default => undefined},
            #{name => cluster, long => "-cluster", type => boolean, default => false},
            #{name => tls, long => "-tls", type => boolean, default => false},
            #{name => tls_cert, long => "-tls-cert", type => string, default => undefined},
            #{name => tls_key, long => "-tls-key", type => string, default => undefined},
            #{name => tls_ca, long => "-tls-ca", type => string, default => undefined},
            #{name => tls_skip_verify, long => "-tls-skip-verify", type => boolean, default => false},
            #{name => scan_size, long => "-scan-size", type => integer, default => 1000},
            #{name => include_types, long => "-include-types", type => boolean, default => true},
            #{name => config, long => "-config", type => string, default => undefined}
        ]
    }.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

-spec normalize(map()) -> map().
normalize(ArgMap) ->
    Host = opt_string(host, ArgMap),
    #{version => maps:get(version, ArgMap, false),
      update => maps:get(update, ArgMap, false),
      scan_size => maps:get(scan_size, ArgMap, 1000),
      include_types => maps:get(include_types, ArgMap, true),
      config_path => opt_string(config, ArgMap),
      connection => connection(ArgMap, Host)}.

-spec connection(map(), binary() | undefined) -> map() | undefined.
connection(_ArgMap, undefined) ->
    undefined;
connection(ArgMap, Host) ->
    Port = maps:get(port, ArgMap, 6379),
    #{name => default_name(opt_string(name, ArgMap), Host, Port),
      host => Host,
      port => Port,
      db => maps:get(db, ArgMap, 0),
      username => opt_string(user, ArgMap),
      password => opt_string(password, ArgMap),
      use_cluster => maps:get(cluster, ArgMap, false),
      use_tls => maps:get(tls, ArgMap, false),
      tls_config => tls_config(ArgMap)}.

-spec tls_config(map()) -> map() | undefined.
tls_config(ArgMap) ->
    case maps:get(tls, ArgMap, false) of
        false ->
            undefined;
        true ->
            #{cert_file => opt_string(tls_cert, ArgMap),
              key_file => opt_string(tls_key, ArgMap),
              ca_file => opt_string(tls_ca, ArgMap),
              insecure_skip_verify => maps:get(tls_skip_verify, ArgMap, false)}
    end.

-spec default_name(binary() | undefined, binary(), integer()) -> binary().
default_name(undefined, Host, Port) ->
    <<Host/binary, ":", (integer_to_binary(Port))/binary>>;
default_name(Name, _Host, _Port) ->
    Name.

-spec opt_string(atom(), map()) -> binary() | undefined.
opt_string(Key, ArgMap) ->
    case maps:get(Key, ArgMap, undefined) of
        undefined -> undefined;
        Value when is_binary(Value) -> Value;
        Value -> unicode:characters_to_binary(Value)
    end.
