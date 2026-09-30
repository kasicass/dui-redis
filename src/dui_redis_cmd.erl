%% @doc Command factories.
%%
%% Wraps side effects in `{exec, Fun}' commands. Results are delivered back to
%% the issuing component as `command_result' events (see educkui E0), so the
%% root component simply handles tagged result tuples in `update/2'.
-module(dui_redis_cmd).

-include("dui_redis.hrl").

-export([load_config/1]).

%% @doc Asynchronously loads configuration from the state's config path.
-spec load_config(#dui_state{}) -> educkui_command:command().
load_config(State) ->
    Path = case dui_redis_state:config_path(State) of
        undefined -> dui_redis_config:path();
        P -> P
    end,
    educkui_command:exec(fun() ->
        {config_loaded, dui_redis_config:load(Path)}
    end).
