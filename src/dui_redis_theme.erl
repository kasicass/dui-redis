%% @doc UI styles for dui-redis.
%%
%% Central place for colours so screens stay consistent and theming can be
%% added later.
-module(dui_redis_theme).

-include_lib("educkui/include/educkui.hrl").

-export([
    title/0,
    subtitle/0,
    selected/0,
    info/0,
    success/0,
    error/0,
    dim/0,
    border/0,
    help_key/0
]).

-spec title() -> #dui_style{}.
title() ->
    educkui_style:from([{fg, cyan}, {bold, true}]).

-spec subtitle() -> #dui_style{}.
subtitle() ->
    educkui_style:from([{fg, bright_black}]).

-spec selected() -> #dui_style{}.
selected() ->
    educkui_style:from([{reverse, true}]).

-spec info() -> #dui_style{}.
info() ->
    educkui_style:from([{fg, blue}]).

-spec success() -> #dui_style{}.
success() ->
    educkui_style:from([{fg, green}]).

-spec error() -> #dui_style{}.
error() ->
    educkui_style:from([{fg, red}, {bold, true}]).

-spec dim() -> #dui_style{}.
dim() ->
    educkui_style:from([{fg, bright_black}]).

-spec border() -> #dui_style{}.
border() ->
    educkui_style:from([{fg, bright_black}]).

-spec help_key() -> #dui_style{}.
help_key() ->
    educkui_style:from([{fg, yellow}, {bold, true}]).
