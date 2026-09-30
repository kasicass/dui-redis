%% @doc Pure search helpers: regex matching, fuzzy scoring and value diffing.
-module(dui_redis_search).

-export([
    regex_match/2,
    compile_regex/1,
    fuzzy_score/2,
    fuzzy_rank/3,
    value_contains/2,
    diff/2
]).

-define(MAX_REGEX_LEN, 1024).

%% @doc Compiles a user regex, rejecting over-long or invalid patterns.
-spec compile_regex(binary()) -> {ok, term()} | {error, term()}.
compile_regex(Pattern) when byte_size(Pattern) > ?MAX_REGEX_LEN ->
    {error, pattern_too_long};
compile_regex(Pattern) ->
    try re:compile(Pattern)
    catch
        error:Reason -> {error, Reason}
    end.

%% @doc True if `Subject' matches `Pattern' (raw binary pattern).
-spec regex_match(binary(), binary()) -> boolean().
regex_match(Pattern, Subject) ->
    case compile_regex(Pattern) of
        {ok, MP} -> re:run(Subject, MP, [{capture, none}]) =:= match;
        {error, _} -> false
    end.

%% @doc Port of redis-tui's fuzzy score. Higher is better; 0 means no match.
-spec fuzzy_score(binary(), binary()) -> non_neg_integer().
fuzzy_score(Subject, Pattern) ->
    SubjectLower = string:lowercase(Subject),
    PatternLower = string:lowercase(Pattern),
    case binary:match(SubjectLower, PatternLower) of
        {_Pos, _Len} ->
            100 + max(0, byte_size(SubjectLower) - byte_size(PatternLower));
        nomatch ->
            subsequence_score(SubjectLower, PatternLower)
    end.

-spec subsequence_score(binary(), binary()) -> non_neg_integer().
subsequence_score(_Subject, <<>>) ->
    0;
subsequence_score(Subject, Pattern) ->
    subseq(Subject, Pattern, 0, 0, 0).

-spec subseq(binary(), binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    non_neg_integer().
subseq(Subject, Pattern, I, P, Score) ->
    case (I >= byte_size(Subject)) orelse (P >= byte_size(Pattern)) of
        true ->
            case P >= byte_size(Pattern) of
                true -> Score;
                false -> 0
            end;
        false ->
            SB = binary:at(Subject, I),
            PB = binary:at(Pattern, P),
            case SB =:= PB of
                true ->
                    Bonus = case I > 0 andalso is_separator(binary:at(Subject, I - 1)) of
                        true -> 5;
                        false -> 0
                    end,
                    subseq(Subject, Pattern, I + 1, P + 1, Score + 10 + Bonus);
                false ->
                    subseq(Subject, Pattern, I + 1, P, Score)
            end
    end.

-spec is_separator(byte()) -> boolean().
is_separator($:) -> true;
is_separator($_) -> true;
is_separator($-) -> true;
is_separator(_) -> false.

%% @doc Returns the top `Max' keys ranked by fuzzy score against `Term'.
-spec fuzzy_rank([map()], binary(), pos_integer()) -> [map()].
fuzzy_rank(Keys, Term, Max) ->
    Scored = lists:filtermap(
        fun(Key) ->
            Score = fuzzy_score(maps:get(key, Key, <<>>), Term),
            case Score > 0 of
                true -> {true, {Score, Key}};
                false -> false
            end
        end,
        Keys),
    Sorted = lists:sort(fun({S1, _}, {S2, _}) -> S1 >= S2 end, Scored),
    [K || {_S, K} <- lists:sublist(Sorted, Max)].

%% @doc True if `Search' appears anywhere in the value's text/items.
-spec value_contains(binary(), map()) -> boolean().
value_contains(Search, Value) ->
    Lines = dui_redis_preview:lines(Value, 10000),
    lists:any(fun(Line) -> binary:match(Line, Search) =/= nomatch end, Lines).

%% @doc Produces a simple line diff between two values' rendered lines.
-spec diff(map(), map()) -> binary().
diff(V1, V2) ->
    L1 = dui_redis_preview:lines(V1, 10000),
    L2 = dui_redis_preview:lines(V2, 10000),
    Removed = subtract(L1, L2),
    Added = subtract(L2, L1),
    Lines = [<<"- ", L/binary>> || L <- Removed] ++ [<<"+ ", L/binary>> || L <- Added],
    case Lines of
        [] -> <<"(identical)">>;
        _ -> iolist_to_binary(lists:join(<<"\n">>, Lines))
    end.

%% @doc Multiset difference: elements of A not present in B.
-spec subtract([binary()], [binary()]) -> [binary()].
subtract(A, B) ->
    lists:foldl(
        fun(E, Acc) -> lists:delete(E, Acc) end,
        A, B).
