%% @doc dui-redis application callback.
-module(dui_redis_app).

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    dui_redis_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
