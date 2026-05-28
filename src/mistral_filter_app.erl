%%%-------------------------------------------------------------------
%%% @doc Mistral AI agent.
%%%
%%% Sends the query to the Mistral API and returns the answer as a
%%% single embryo map.
%%%
%%% Maintains a conversation memory (list of {query, answer} pairs)
%%% so the LLM can reference prior exchanges in its context window.
%%% Memory is kept in ETS so it survives worker restarts.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, NewMemory}.
%%% Memory schema: #{history => [{QueryBin, AnswerBin}]} (newest last).
%%% @end
%%%-------------------------------------------------------------------
-module(mistral_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(MAX_HISTORY, 5).

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"mistral">>, <<"llm">>,
                                      <<"summarize">>, <<"generate">>,
                                      <<"cloud_ai">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case mistral_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(mistral_filter_query_listener),
    catch em_pop_sup:stop_node(mistral_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(mistral_filter, pop_port,   9466),
    QueryPort = application:get_env(mistral_filter, query_port, 9467),
    Seeds     = application:get_env(mistral_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(mistral_filter),
    catch cowboy:stop_listener(mistral_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(mistral_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => mistral_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(mistral_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[mistral_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    Value = extract_value(Body),
    case Value of
        "" -> {[], Memory};
        _  ->
            History  = maps:get(history, Memory, []),
            Config   = mistral_handler:get_env_config(),
            ValueBin = unicode:characters_to_binary(Value, unicode, utf8),
            Messages = history_to_messages(History, ValueBin),
            case mistral_handler:chat(Messages, Config) of
                {ok, AnswerBin} ->
                    Embryo     = #{<<"properties">> => #{<<"resume">> => AnswerBin}},
                    NewHistory = trim_history(
                        History ++ [{ValueBin, AnswerBin}],
                        ?MAX_HISTORY),
                    {[Embryo], Memory#{history => NewHistory}};
                {error, Reason} ->
                    io:format("[mistral] chat failed: ~p~n", [Reason]),
                    {[], Memory}
            end
    end;

handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Internal helpers
%%====================================================================

history_to_messages(History, CurrentQuery) ->
    HistoryMessages = lists:flatmap(fun({Q, A}) ->
        [
            #{<<"role">> => <<"user">>,      <<"content">> => Q},
            #{<<"role">> => <<"assistant">>, <<"content">> => A}
        ]
    end, History),
    HistoryMessages ++ [#{<<"role">> => <<"user">>, <<"content">> => CurrentQuery}].

extract_value(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            binary_to_list(maps:get(<<"value">>, Map,
                maps:get(<<"query">>, Map, <<"">>)));
        _ ->
            binary_to_list(JsonBinary)
    catch
        _:_ -> binary_to_list(JsonBinary)
    end.

trim_history(History, Max) ->
    Len = length(History),
    case Len > Max of
        true  -> lists:nthtail(Len - Max, History);
        false -> History
    end.
