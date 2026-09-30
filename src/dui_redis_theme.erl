%% @doc UI styles for dui-redis.
%%
%% Mirrors redis-tui's palette (256-color indexes): accent `39', white `15',
%% key cyan `6', plus per-type colors. Selection is a dark-on-accent band
%% (`fg 16', `bg 39'), matching redis-tui rather than reverse video.
-module(dui_redis_theme).

-include_lib("educkui/include/educkui.hrl").

-export([
    title/0,
    header/0,
    normal/0,
    selected/0,
    key_accent/0,
    logo/0,
    info/0,
    success/0,
    error/0,
    dim/0,
    help/0,
    meta_dim/0,
    border/0,
    subtitle/0,
    help_key/0,
    type_style/1,
    type_style_bold/1,
    ttl_style/1,
    type_color/1,
    pad/2,
    spaces/1
]).

-spec title() -> #dui_style{}.
title() -> educkui_style:from([{fg, 39}, {bold, true}]).

-spec header() -> #dui_style{}.
header() -> educkui_style:from([{fg, 15}, {bold, true}]).

-spec normal() -> #dui_style{}.
normal() -> educkui_style:from([{fg, 15}]).

-spec selected() -> #dui_style{}.
selected() -> educkui_style:from([{fg, 16}, {bg, 39}, {bold, true}]).

%% @doc Accent used for the "Filter:" label and other keys.
-spec key_accent() -> #dui_style{}.
key_accent() -> educkui_style:from([{fg, 6}, {bold, true}]).

%% @doc The connections-screen logo (red bold, like redis-tui).
-spec logo() -> #dui_style{}.
logo() -> educkui_style:from([{fg, 196}, {bold, true}]).

-spec info() -> #dui_style{}.
info() -> educkui_style:from([{fg, 39}]).

-spec success() -> #dui_style{}.
success() -> educkui_style:from([{fg, 2}]).

-spec error() -> #dui_style{}.
error() -> educkui_style:from([{fg, 1}]).

-spec dim() -> #dui_style{}.
dim() -> educkui_style:from([{fg, 245}]).

-spec help() -> #dui_style{}.
help() -> educkui_style:from([{fg, 246}]).

-spec meta_dim() -> #dui_style{}.
meta_dim() -> educkui_style:from([{fg, 250}]).

-spec border() -> #dui_style{}.
border() -> educkui_style:from([{fg, 240}]).

%% Backwards-compatible aliases.
-spec subtitle() -> #dui_style{}.
subtitle() -> dim().

-spec help_key() -> #dui_style{}.
help_key() -> educkui_style:from([{fg, 3}, {bold, true}]).

%% ---------------------------------------------------------------------------
%% Per-type colors (redis-tui's typeStyleMap)
%% ---------------------------------------------------------------------------

-spec type_style(atom()) -> #dui_style{}.
type_style(Type) -> educkui_style:from([{fg, type_color(Type)}]).

-spec type_style_bold(atom()) -> #dui_style{}.
type_style_bold(Type) -> educkui_style:from([{fg, type_color(Type)}, {bold, true}]).

-spec type_color(atom()) -> 0..255.
type_color(string) -> 2;
type_color(list) -> 3;
type_color(set) -> 4;
type_color(zset) -> 5;
type_color(hash) -> 6;
type_color(stream) -> 13;
type_color(json) -> 208;
type_color(hll) -> 9;
type_color(bitmap) -> 12;
type_color(geo) -> 10;
type_color(protobuf) -> 141;
type_color(_) -> 15.

%% @doc TTL color: critical for TTLs under 60s (red bold), warning under 1h
%% (yellow), otherwise green; no-expiry/expired are dim.
-spec ttl_style(integer()) -> #dui_style{}.
ttl_style(S) when is_integer(S), S > 0, S < 60 -> educkui_style:from([{fg, 1}, {bold, true}]);
ttl_style(S) when is_integer(S), S > 0, S < 3600 -> educkui_style:from([{fg, 3}]);
ttl_style(S) when is_integer(S), S > 0 -> educkui_style:from([{fg, 2}]);
ttl_style(_) -> educkui_style:from([{fg, 245}]).

%% ---------------------------------------------------------------------------
%% Text helpers
%% ---------------------------------------------------------------------------

%% @doc Truncates and right-pads `Bin' to `Width' display-friendly columns.
-spec pad(binary(), non_neg_integer()) -> binary().
pad(_Bin, Width) when Width =< 0 -> <<>>;
pad(Bin, Width) ->
    {Truncated, Used} = educkui_display_width:truncate(Bin, Width),
    case Width - Used of
        N when N =< 0 -> Truncated;
        N -> <<Truncated/binary, (spaces(N))/binary>>
    end.

-spec spaces(non_neg_integer()) -> binary().
spaces(0) -> <<>>;
spaces(N) when N > 0 -> binary:copy(<<" ">>, N).
