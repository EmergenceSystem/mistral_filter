%%%-------------------------------------------------------------------
%%% @doc Mistral AI filter.
%%%
%%% Sends the query directly to Mistral API and returns the answer
%%% as a single embryo map.
%%% @end
%%%-------------------------------------------------------------------
-module(mistral_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/1]).

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_filter(mistral_filter, ?MODULE).

stop(_State) ->
    em_filter:stop_filter(mistral_filter).

%%====================================================================
%% Filter handler — returns a list of embryo maps
%%====================================================================

handle(Body) when is_binary(Body) ->
    generate_embryo_list(Body);
handle(_) ->
    [].

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    Value = extract_value(JsonBinary),
    generate_embryos(Value).

extract_value(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            binary_to_list(maps:get(<<"value">>, Map, <<"">>));
        _ -> ""
    catch
        _:_ -> ""
    end.

generate_embryos("") -> [];
generate_embryos(Value) ->
    ValueBin = unicode:characters_to_binary(Value, unicode, utf8),
    Config   = mistral_handler:get_env_config(),
    case mistral_handler:generate(ValueBin, Config) of
        {ok, AnswerBin} ->
            [#{<<"properties">> => #{<<"resume">> => AnswerBin}}];
        _ ->
            []
    end.
