%% @doc dui-redis entry point.
%%
%% Parses CLI arguments and starts the educkui runtime with
%% `dui_redis_root' as the root component. Also usable as an escript entry
%% point via `main/1'.
-module(dui_redis).

-include("dui_redis.hrl").

-export([main/1, run/1, version/0]).

%% @doc escript entry point.
-spec main([string()]) -> ok | {error, term()}.
main(Args) ->
    run(Args).

%% @doc Parses `Args' and runs the application (or prints version and exits).
-spec run([string()]) -> ok | {error, term()}.
run(Args) ->
    case dui_redis_cli:parse(Args) of
        {error, Reason} ->
            io:format(standard_error, "~ts~n", [dui_redis_cli:format_error(Reason)]),
            {error, Reason};
        {ok, Opts} ->
            case maps:get(version, Opts, false) of
                true ->
                    io:format("dui-redis ~s~n", [version()]),
                    ok;
                false ->
                    start(Opts)
            end
    end.

-spec start(map()) -> ok | {error, term()}.
start(Opts) ->
    {ok, _Started} = application:ensure_all_started(dui_redis),
    Result = educkui:run([
        {root, dui_redis_root},
        {init_args, [{opts, Opts}]}
    ]),
    _ = application:stop(dui_redis),
    Result.

%% @doc Returns the application version string.
-spec version() -> string().
version() ->
    ?DUI_REDIS_VERSION.
