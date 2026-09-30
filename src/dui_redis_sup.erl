%% @doc Top-level supervisor for dui-redis.
-module(dui_redis_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Client = #{id => dui_redis_client,
               start => {dui_redis_client, start_link, []},
               restart => permanent,
               shutdown => 5000,
               type => worker,
               modules => [dui_redis_client]},
    {ok, {SupFlags, [Client]}}.
