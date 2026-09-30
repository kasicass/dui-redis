-module(dui_redis_vault_tests).

-include_lib("eunit/include/eunit.hrl").

select_nested_test() ->
    Data = #{<<"credentials">> => #{<<"redis">> => #{<<"password">> => <<"s3cret">>}}},
    ?assertEqual(<<"s3cret">>, dui_redis_vault:select(Data, <<"credentials.redis.password">>)).

select_missing_test() ->
    Data = #{<<"a">> => #{<<"b">> => <<"c">>}},
    ?assertEqual(undefined, dui_redis_vault:select(Data, <<"a.z">>)),
    ?assertEqual(undefined, dui_redis_vault:select(Data, <<"x.y.z">>)).

select_top_level_test() ->
    ?assertEqual(<<"v">>, dui_redis_vault:select(#{<<"k">> => <<"v">>}, <<"k">>)).

maybe_resolve_no_vault_test() ->
    Conn = #{host => <<"localhost">>, port => 6379},
    ?assertEqual({ok, Conn}, dui_redis_vault:maybe_resolve(Conn)).

maybe_resolve_empty_vault_test() ->
    Conn = #{host => <<"localhost">>, vault_path => <<>>},
    ?assertEqual({ok, Conn}, dui_redis_vault:maybe_resolve(Conn)).
