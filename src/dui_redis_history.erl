%% @doc In-memory value history (never persisted; values may contain secrets).
-module(dui_redis_history).

-export([new/0, new/1, add/4, entries/1, entries/2, clear/1]).

-type entry() :: map().
-type history() :: map().
-export_type([entry/0, history/0]).

-spec new() -> history().
new() -> new(50).

-spec new(pos_integer()) -> history().
new(Max) -> #{max => Max, entries => []}.

%% @doc Records `Value' for `Key' with an `Action' label.
-spec add(history(), binary(), map(), binary()) -> history().
add(Hist, Key, Value, Action) ->
    Entry = #{key => Key, value => Value, action => Action,
              time => erlang:system_time(second)},
    Entries = [Entry | maps:get(entries, Hist)],
    Max = maps:get(max, Hist),
    Hist#{entries := lists:sublist(Entries, Max)}.

-spec entries(history()) -> [entry()].
entries(Hist) -> maps:get(entries, Hist).

%% @doc Entries for a specific key, newest first.
-spec entries(history(), binary()) -> [entry()].
entries(Hist, Key) ->
    [E || E <- entries(Hist), maps:get(key, E) =:= Key].

-spec clear(history()) -> history().
clear(Hist) -> Hist#{entries := []}.
