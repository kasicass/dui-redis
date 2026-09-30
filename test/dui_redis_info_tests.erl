-module(dui_redis_info_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SAMPLE, <<"# Server\r\n"
                  "redis_version:7.2.0\r\n"
                  "redis_mode:standalone\r\n"
                  "os:Linux 6.1\r\n"
                  "\r\n"
                  "# Memory\r\n"
                  "used_memory:1024\r\n"
                  "used_memory_human:1.00K\r\n"
                  "mem_fragmentation_ratio:1.25\r\n"
                  "\r\n"
                  "# Stats\r\n"
                  "keyspace_hits:10\r\n"
                  "keyspace_misses:5\r\n">>).

parse_fields_test() ->
    Info = dui_redis_info:parse(?SAMPLE),
    ?assertEqual(<<"7.2.0">>, dui_redis_info:get(<<"redis_version">>, Info)),
    ?assertEqual(<<"Linux 6.1">>, dui_redis_info:get(<<"os">>, Info)),
    ?assertEqual(<<"1.00K">>, dui_redis_info:get(<<"used_memory_human">>, Info)),
    ?assertEqual(undefined, dui_redis_info:get(<<"nope">>, Info)),
    ?assertEqual(<<"fallback">>, dui_redis_info:get(<<"nope">>, Info, <<"fallback">>)).

int_and_float_test() ->
    Info = dui_redis_info:parse(?SAMPLE),
    ?assertEqual(1024, dui_redis_info:int(<<"used_memory">>, Info)),
    ?assertEqual(10, dui_redis_info:int(<<"keyspace_hits">>, Info)),
    ?assertEqual(undefined, dui_redis_info:int(<<"nope">>, Info)),
    ?assertEqual(1.25, dui_redis_info:float(<<"mem_fragmentation_ratio">>, Info)),
    ?assertEqual(undefined, dui_redis_info:float(<<"os">>, Info)).

sections_test() ->
    ?assertEqual([<<"Server">>, <<"Memory">>, <<"Stats">>],
                 dui_redis_info:sections(?SAMPLE)).

empty_test() ->
    ?assertEqual(#{}, dui_redis_info:parse(<<>>)).
