-module(mistral_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/1]).

start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    FilterUrl = io_lib:format("http://localhost:~p/query", [Port]),
    io:format("Mistral filter registered: ~s~n", [lists:flatten(FilterUrl)]),
    em_filter:register_filter(lists:flatten(FilterUrl)),
    em_filter_sup:start_link(mistral_filter, ?MODULE, Port).

stop(_State) -> ok.

handle(Body) when is_binary(Body) ->
    handle(binary_to_list(Body));
handle(Body) when is_list(Body) ->
    io:format("Mistral Filter received body: ~p~n", [Body]),
    EmbryoList = generate_embryo_list(list_to_binary(Body)),
    Response = #{embryo_list => EmbryoList},
    jsone:encode(Response);
handle(_) ->
    jsone:encode(#{error => <<"Invalid request body">>}).

generate_embryo_list(JsonBinary) ->
    case jsone:decode(JsonBinary, [{keys, atom}]) of
        SearchMap when is_map(SearchMap) ->
            Value = maps:get(value, SearchMap, <<"">>),
            generate_embryos(binary_to_list(Value));
        _ ->
            generate_embryos("")
    end.

generate_embryos("") -> [];
generate_embryos(Value) ->
    io:format("Mistral direct question: ~s~n", [Value]),
    
    %% Appel DIRECT à Mistral (sans résumé)
    ValueBin = unicode:characters_to_binary(Value, unicode, utf8),
    Config = mistral_handler:get_env_config(),
    
    case mistral_handler:generate(ValueBin, Config) of
        {ok, AnswerBin} ->
            io:format("✅ Mistral answer: ~s~n", [AnswerBin]),
            [#{properties => #{resume => AnswerBin}}];
        {error, Reason} ->
            io:format("❌ Mistral error: ~p~n", [Reason]),
            []
    end.

