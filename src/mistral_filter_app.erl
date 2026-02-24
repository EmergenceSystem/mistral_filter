%%%-------------------------------------------------------------------
%%% @doc Mistral AI agent.
%%%
%%% Sends the query to the Mistral API and returns the answer
%%% as a single embryo map.
%%%
%%% Maintains a conversation memory (list of {query, answer} pairs)
%%% so the LLM can reference prior exchanges in its context window.
%%% Mistral natively supports multi-turn via its messages API, so
%%% history maps directly to {role: user/assistant} pairs.
%%%
%%% Handler contract: `handle/2' (Body, Memory) -> {RawList, NewMemory}.
%%% Memory schema: `#{history => [{QueryBin, AnswerBin}]}' (newest last).
%%% @end
%%%-------------------------------------------------------------------
-module(mistral_filter_app).
-behaviour(application).
-export([start/2, stop/1]).
-export([handle/2]).
-define(CAPABILITIES, [
    <<"mistral">>,
    <<"llm">>,
    <<"summarize">>,
    <<"generate">>,
    <<"cloud_ai">>
]).
-define(MAX_HISTORY, 5).
%%====================================================================
%% Application behaviour
%%====================================================================
start(_StartType, _StartArgs) ->
    em_filter:start_agent(mistral_filter, ?MODULE, #{
        capabilities => ?CAPABILITIES,
        memory       => ets
    }).
stop(_State) ->
    em_filter:stop_agent(mistral_filter).
%%====================================================================
%% Agent handler
%%====================================================================
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
            binary_to_list(maps:get(<<"value">>, Map, <<"">>));
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
