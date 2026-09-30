%% @doc Pure prefix-tree builder for key names.
%%
%% Splits keys on a separator (default `:') and merges common prefixes into a
%% tree. Nodes are rendered by the caller with `flatten/2' honouring an
%% expansion set.
-module(dui_redis_tree).

-export([build/2, flatten/2, all_paths/1]).

-type tree_node() :: map().
-export_type([node/0]).

%% @doc Builds a forest of nodes from `Keys' split on `Separator'.
-spec build([binary()], binary()) -> [tree_node()].
build(Keys, Separator) ->
    Tree = lists:foldl(
        fun(Key, Acc) -> insert(Acc, split(Key, Separator), <<>>, Key) end,
        #{}, Keys),
    children_list(Tree).

%% @doc Flattens the forest into `{Depth, Node}' pairs, descending into nodes
%% whose `path' is in `Expanded'.
-spec flatten([tree_node()], sets:set() | [binary()]) -> [{non_neg_integer(), tree_node()}].
flatten(Nodes, Expanded) ->
    ExpandedSet = to_set(Expanded),
    lists:flatmap(fun(Node) -> flatten_node(Node, 0, ExpandedSet) end, Nodes).

%% @doc Returns every node path in the forest.
-spec all_paths([tree_node()]) -> [binary()].
all_paths(Nodes) ->
    lists:flatmap(
        fun(Node) ->
            Path = maps:get(path, Node),
            [Path | all_paths(maps:get(children, Node, []))]
        end,
        Nodes).

%% ---------------------------------------------------------------------------

-spec insert(map(), [binary()], binary(), binary()) -> map().
insert(Tree, [Part], Prefix, Full) ->
    Path = join_path(Prefix, Part),
    Node = maps:get(Part, Tree, #{name => Part, path => Path,
                                  is_key => false, children => #{}}),
    maps:put(Part, Node#{is_key => true, path => Full}, Tree);
insert(Tree, [Part | Rest], Prefix, Full) ->
    Path = join_path(Prefix, Part),
    Node = maps:get(Part, Tree, #{name => Part, path => Path,
                                  is_key => false, children => #{}}),
    Children = maps:get(children, Node),
    Node1 = Node#{children => insert(Children, Rest, Path, Full)},
    maps:put(Part, Node1, Tree).

-spec children_list(map()) -> [tree_node()].
children_list(Tree) ->
    [Node#{children => children_list(maps:get(children, Node))}
     || {_Part, Node} <- lists:sort(maps:to_list(Tree))].

-spec flatten_node(tree_node(), non_neg_integer(), sets:set()) -> [{non_neg_integer(), tree_node()}].
flatten_node(Node, Depth, Expanded) ->
    Children = maps:get(children, Node, []),
    Self = [{Depth, Node}],
    case sets:is_element(maps:get(path, Node), Expanded) of
        true ->
            Self ++ lists:flatmap(
                fun(C) -> flatten_node(C, Depth + 1, Expanded) end, Children);
        false ->
            Self
    end.

-spec split(binary(), binary()) -> [binary()].
split(Key, <<>>) -> [Key];
split(Key, Separator) -> binary:split(Key, Separator, [global]).

-spec join_path(binary(), binary()) -> binary().
join_path(<<>>, Part) -> Part;
join_path(Prefix, Part) -> <<Prefix/binary, ":", Part/binary>>.

-spec to_set(sets:set() | [binary()]) -> sets:set().
to_set(Set) when is_tuple(Set) -> Set;
to_set(List) when is_list(List) -> sets:from_list(List).
