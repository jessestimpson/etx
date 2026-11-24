-module(etx_tests).

-include_lib("eunit/include/eunit.hrl").

%% The tests run on one node with two clusters of one node each:
%% `default' and `second'.
etx_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 60, fun basics/0},
        {timeout, 60, fun order/0},
        {timeout, 60, fun keypos/0},
        {timeout, 60, fun counters/0},
        {timeout, 60, fun equal_keys/0},
        {timeout, 60, fun match_specs/0},
        {timeout, 120, fun model/0},
        {timeout, 60, fun transactions/0},
        {timeout, 120, fun concurrent/0},
        {timeout, 60, fun two_clusters/0},
        {timeout, 60, fun restart/0}
    ]}.

dir() ->
    filename:join([filename:basedir(user_cache, "etx_test"), integer_to_list(erlang:unique_integer([positive]))]).

setup() ->
    _ = application:load(etx),
    ok = application:set_env(etx, clusters, #{default => #{dir => dir()}, second => #{dir => dir()}}),
    {ok, _} = application:ensure_all_started(etx),
    ok.

cleanup(_) ->
    _ = application:stop(etx),
    _ = application:stop(redwall),
    _ = application:stop(peace),
    ok = application:unset_env(etx, clusters).

%% Waits until the cluster is healthy. A StorageServer is current when it
%% has a version, so the function first writes an object.
await_healthy(Cluster, 0) ->
    error({not_healthy, etx:status(Cluster)});
await_healthy(Cluster, Attempts) ->
    true = etx:insert(etx:open(health, [{cluster, Cluster}]), {a, 1}),
    case etx:status(Cluster) of
        Status = #{healthy := true} ->
            Status;
        _ ->
            timer:sleep(50),
            await_healthy(Cluster, Attempts - 1)
    end.

%% A table name that no other test uses.
name() ->
    {table, erlang:unique_integer([positive])}.

basics() ->
    ?assertEqual([default, second], etx:clusters()),
    %% A cluster of one node is healthy, and no node can stop.
    ?assertMatch(
        #{
            healthy := true,
            coordinators := #{total := 1, up := 1, majority := 1},
            logs := #{total := 3, up := 3, replication := 2},
            storages := #{total := 1, current := 1},
            fault_tolerance := #{
                max_node_failures_without_losing_data := 0,
                max_node_failures_without_losing_availability := 0,
                safe_to_stop := []
            }
        },
        await_healthy(default, 100)
    ),
    ?assertMatch(#{healthy := true}, await_healthy(second, 100)),
    ?assertError(badarg, etx:status(none)),
    T = etx:open(name()),
    ?assertEqual([], etx:lookup(T, a)),
    ?assertEqual(false, etx:member(T, a)),
    ?assertEqual(true, etx:insert(T, {a, 1})),
    ?assertEqual(true, etx:insert(T, [{b, 2}, {c, 3, extra}])),
    ?assertEqual([{a, 1}], etx:lookup(T, a)),
    ?assertEqual([{c, 3, extra}], etx:lookup(T, c)),
    ?assertEqual(true, etx:member(T, b)),
    %% A second object with the key of an object replaces the object.
    ?assertEqual(true, etx:insert(T, {a, one})),
    ?assertEqual([{a, one}], etx:lookup(T, a)),
    ?assertEqual(false, etx:insert_new(T, {a, two})),
    ?assertEqual(false, etx:insert_new(T, [{d, 4}, {a, two}])),
    ?assertEqual([], etx:lookup(T, d)),
    ?assertEqual(true, etx:insert_new(T, [{d, 4}, {e, 5}])),
    ?assertEqual(one, etx:lookup_element(T, a, 2)),
    ?assertError(badarg, etx:lookup_element(T, a, 3)),
    ?assertError(badarg, etx:lookup_element(T, none, 2)),
    ?assertEqual(default, etx:lookup_element(T, none, 2, default)),
    ?assertEqual(5, etx:info(T, size)),
    ?assertEqual([{a, one}, {b, 2}, {c, 3, extra}, {d, 4}, {e, 5}], etx:tab2list(T)),
    ?assertEqual([a, b, c, d, e], lists:reverse(etx:foldl(fun(Object, Acc) -> [element(1, Object) | Acc] end, [], T))),
    ?assertEqual([a, b, c, d, e], etx:foldr(fun(Object, Acc) -> [element(1, Object) | Acc] end, [], T)),
    ?assertEqual([{e, 5}], etx:take(T, e)),
    ?assertEqual([], etx:take(T, e)),
    ?assertEqual(true, etx:delete(T, d)),
    ?assertEqual(true, etx:delete(T, d)),
    ?assertEqual(true, etx:delete_object(T, {b, other})),
    ?assertEqual([{b, 2}], etx:lookup(T, b)),
    ?assertEqual(true, etx:delete_object(T, {b, 2})),
    ?assertEqual([{a, one}, {c, 3, extra}], etx:tab2list(T)),
    ?assertError(badarg, etx:insert(T, not_a_tuple)),
    ?assertError(badarg, etx:insert(T, {})),
    ?assertEqual(true, etx:delete_all_objects(T)),
    ?assertEqual([], etx:tab2list(T)),
    ?assertEqual(0, etx:info(T, size)),
    ?assertMatch([{name, _}, {cluster, default}, {type, ordered_set}, {keypos, 1}, {size, 0}], etx:info(T)),
    %% A second handle of the table, and the delete of the table.
    Name = etx:info(T, name),
    true = etx:insert(T, {x, 1}),
    ?assertEqual([{x, 1}], etx:lookup(etx:open(Name, [set, {cluster, default}]), x)),
    ?assertEqual(true, etx:delete(T)),
    ?assertEqual([], etx:tab2list(etx:open(Name))),
    ?assertError(badarg, etx:open(name(), [bag])),
    ?assertError(badarg, etx:open(name(), [{cluster, none}])),
    ?assertError(badarg, etx:lookup(not_a_table, a)).

%% The keys are in the order of the Erlang terms.
order() ->
    T = etx:open(name()),
    ?assertEqual('$end_of_table', etx:first(T)),
    ?assertEqual('$end_of_table', etx:last(T)),
    Keys = [3, 1, 2.5, b, a, {t, 2}, {t, 1}, "list", <<"binary">>, [], #{m => 1}, {}, -7],
    true = etx:insert(T, [{Key, value} || Key <- Keys]),
    Sorted = lists:sort(Keys),
    ?assertEqual(Sorted, [Key || {Key, value} <- etx:tab2list(T)]),
    ?assertEqual(hd(Sorted), etx:first(T)),
    ?assertEqual(lists:last(Sorted), etx:last(T)),
    Forward = fun Walk('$end_of_table') -> []; Walk(Key) -> [Key | Walk(etx:next(T, Key))] end,
    Backward = fun Walk('$end_of_table') -> []; Walk(Key) -> [Key | Walk(etx:prev(T, Key))] end,
    ?assertEqual(Sorted, Forward(etx:first(T))),
    ?assertEqual(lists:reverse(Sorted), Backward(etx:last(T))),
    %% A key that the table does not have.
    ?assertEqual(3, etx:next(T, 2.7)),
    ?assertEqual(2.5, etx:prev(T, 2.7)),
    ?assertEqual('$end_of_table', etx:next(T, <<"z">>)),
    ?assertEqual('$end_of_table', etx:prev(T, -100)).

%% The option `keypos'.
keypos() ->
    Name = name(),
    T = etx:open(Name, [{keypos, 2}]),
    true = etx:insert(T, [{user, 2, <<"b">>}, {user, 1, <<"a">>}]),
    ?assertEqual([{user, 1, <<"a">>}], etx:lookup(T, 1)),
    ?assertEqual([{user, 1, <<"a">>}, {user, 2, <<"b">>}], etx:tab2list(T)),
    ?assertEqual(1, etx:first(T)),
    ?assertError(badarg, etx:insert(T, {short})),
    ?assertEqual(11, etx:update_counter(T, 9, {3, 1}, {user, key, 10})),
    ?assertEqual([{user, 9, 11}], etx:lookup(T, 9)),
    ?assertError(badarg, etx:update_counter(T, 9, {2, 1})),
    %% The table keeps its `keypos'.
    ?assertEqual(2, etx:info(etx:open(Name), keypos)),
    ?assertEqual(2, etx:info(etx:open(Name, [{keypos, 2}]), keypos)),
    ?assertError(badarg, etx:open(Name, [{keypos, 1}])),
    ?assertError(badarg, etx:open(name(), [{keypos, 0}])).

%% `update_counter' and `update_element' give the results of ets.
counters() ->
    T = etx:open(name()),
    E = ets:new(model, [ordered_set]),
    Both = fun(F, Args) ->
        Expected =
            try
                {ok, apply(ets, F, [E | Args])}
            catch
                error:badarg -> badarg
            end,
        Actual =
            try
                {ok, apply(etx, F, [T | Args])}
            catch
                error:badarg -> badarg
            end,
        ?assertEqual(Expected, Actual, {F, Args}),
        ?assertEqual(ets:tab2list(E), etx:tab2list(T), {F, Args})
    end,
    Both(insert, [[{a, 0}, {b, 10, 20, text}]]),
    [
        Both(update_counter, Args)
     || Args <- [
            [a, 1],
            [a, -5],
            [a, {2, 7}],
            [b, {3, 5}],
            [b, [{2, 1}, {3, -1}, {2, 1}]],
            [b, {2, 1, 12, 0}],
            [b, {2, 1, 12, 0}],
            [b, {2, -4, -1, 100}],
            [b, {4, 1}],
            [b, {1, 1}],
            [b, {9, 1}],
            [none, 1],
            [none, 1, {none, 41}],
            [other, {2, 2}, {ignored, 0}],
            [third, [{2, 1}, {3, 1}], {third, 0, 0}]
        ]
    ],
    [
        Both(update_element, Args)
     || Args <- [[a, {2, new}], [b, [{2, x}, {4, y}]], [none2, {2, x}], [b, {9, x}], [b, {1, x}]]
    ],
    true = ets:delete(E).

%% Two keys that are equal and not identical are one key, as in an ETS
%% table of the type `ordered_set': an integer and a float with the same
%% value. Each function gives the result of ets, and the keys of every
%% type are in the order of ets.
equal_keys() ->
    T = etx:open(name()),
    E = ets:new(model, [ordered_set]),
    Both = fun(F, Args) ->
        Expected =
            try
                {ok, apply(ets, F, [E | Args])}
            catch
                error:badarg -> badarg
            end,
        Actual =
            try
                {ok, apply(etx, F, [T | Args])}
            catch
                error:badarg -> badarg
            end,
        ?assert(Expected =:= Actual, {F, Args, Expected, Actual})
    end,
    Objects = [
        {1, int},
        {2.0, float},
        {a, atom},
        {[l], list},
        {{t, 1}, tuple},
        {<<"b">>, bin},
        {#{m => 1}, map},
        {"str", string},
        {[], nil},
        {-3, neg},
        {1.5, f}
    ],
    Calls =
        [{insert, [Objects]}, {tab2list, []}, {first, []}, {last, []}] ++
            [{F, [K]} || F <- [lookup, member], K <- [1, 1.0, 2, 2.0, 1.5]] ++
            [{insert, [{1.0, replaced}]}, {tab2list, []}, {lookup, [1]}, {first, []}, {insert_new, [{2, new}]}, {lookup_element, [2, 2]}] ++
            [{F, [K]} || F <- [next, prev], K <- [1, 1.0, 0.5, 2, 2.0, -3, a, {t, 1}, #{m => 1}, [], "str", [l], <<"b">>]] ++
            [{select, [[{{K, '$2'}, [], ['$2']}]]} || K <- [1, 1.0, 2, 2.0]] ++
            [{F, [{K, '_'}]} || F <- [match, match_object], K <- [1, 1.0, 2, 2.0]] ++
            [
                {select, [[{{'$1', '_'}, [{is_number, '$1'}], ['$1']}]]},
                {select, [[{{'$1', '_'}, [{'>', '$1', 1}], ['$1']}]]},
                {update_counter, [3, 1, {3, 0}]},
                {update_counter, [3.0, 1]},
                {lookup, [3]},
                {delete, [2]},
                {tab2list, []},
                {delete, [1.0]},
                {take, [3.0]},
                {delete_object, [{1.5, f}]},
                {select_delete, [[{{'$1', '_'}, [{is_atom, '$1'}], [true]}]]},
                {tab2list, []}
            ],
    [Both(F, Args) || {F, Args} <- Calls],
    ?assert(ets:tab2list(E) =:= etx:tab2list(T)),
    true = ets:delete(E).

%% The functions with a match spec and with a pattern.
match_specs() ->
    T = etx:open(name()),
    E = ets:new(model, [ordered_set]),
    Objects = [{{user, I}, #{status => case I rem 3 of 0 -> active; _ -> idle end}, I * 10} || I <- lists:seq(1, 30)],
    true = etx:insert(T, Objects),
    true = ets:insert(E, Objects),
    Specs = [
        [{'_', [], ['$_']}],
        [{{'$1', '$2', '$3'}, [], ['$$']}],
        [{{{user, '$1'}, #{status => active}, '_'}, [], ['$1']}],
        [{{{user, '$1'}, '_', '$2'}, [{'>', '$2', 100}, {'<', '$1', 20}], [{{'$1', '$2', '$_'}}]}],
        [{{'$1', '_', '$2'}, [{'=:=', {element, 3, '$_'}, 50}], ['$1', {const, '$_'}]}],
        %% The key of each pattern has no variable.
        [{{{user, 7}, '_', '$1'}, [], ['$1']}],
        [{{{user, 9}, '$1', '_'}, [], ['$_']}, {{{user, 3}, '_', '_'}, [], [first]}, {{{user, 99}, '_', '_'}, [], [none]}],
        [{{{user, 5}, '_', '$1'}, [{'>', '$1', 1000}], ['$1']}],
        %% A clause with a key, and a clause without one.
        [{{{user, 4}, '_', '_'}, [], [four]}, {{'_', '_', 300}, [], [last]}],
        [{{'_', '_', '_'}, [], [true]}],
        [{no_tuple, [], ['$_']}]
    ],
    lists:foreach(
        fun(Spec) ->
            ?assertEqual(ets:select(E, Spec), etx:select(T, Spec), Spec),
            ?assertEqual(ets:select_count(E, Spec), etx:select_count(T, Spec), Spec),
            %% A limit and the continuation.
            Chunks = fun
                Read('$end_of_table') -> [];
                Read({Results, Continuation}) -> [Results | Read(etx:select(Continuation))]
            end,
            All = Chunks(etx:select(T, Spec, 4)),
            ?assertEqual(ets:select(E, Spec), lists:append(All), Spec),
            ?assert(lists:all(fun(Chunk) -> length(Chunk) =< 4 andalso Chunk =/= [] end, All), Spec)
        end,
        Specs
    ),
    Patterns = [{'$1', '_', '$2'}, {{user, '$1'}, #{status => idle}, '_'}, {{user, 12}, '$1', '$2'}, {'_', '_', 40}, '_', {a}],
    lists:foreach(
        fun(Pattern) ->
            ?assertEqual(ets:match(E, Pattern), etx:match(T, Pattern), Pattern),
            ?assertEqual(ets:match_object(E, Pattern), etx:match_object(T, Pattern), Pattern)
        end,
        Patterns
    ),
    ?assertError(badarg, etx:select(T, no_spec)),
    ?assertError(badarg, etx:select(T, [{no_clause}])),
    ?assertError(badarg, etx:select(T, [{'_', [], []}])),
    ?assertError(badarg, etx:select(T, [{'_', [{no_guard_function, '$1'}], ['$_']}])),
    %% The deletes.
    Delete = [{{{user, '$1'}, '_', '_'}, [{'=:=', {'rem', '$1', 2}, 0}], [true]}, {{{user, 1}, '_', '_'}, [], [false]}],
    ?assertEqual(ets:select_delete(E, Delete), etx:select_delete(T, Delete)),
    ?assertEqual(ets:tab2list(E), etx:tab2list(T)),
    ?assertEqual(ets:match_delete(E, {'_', #{status => active}, '_'}), etx:match_delete(T, {'_', #{status => active}, '_'})),
    ?assertEqual(ets:tab2list(E), etx:tab2list(T)),
    ?assertEqual(10, length(etx:tab2list(T))),
    true = ets:delete(E).

%% 600 random functions on a table of etx and on an ETS table of the type
%% `ordered_set' give the same results.
model() ->
    T = etx:open(name()),
    E = ets:new(model, [ordered_set]),
    %% Some keys are equal and not identical: 1 and 1.0, 3 and 3.0,
    %% `{k, 1}' and `{k, 1.0}'.
    Keys = [1, 2, 3, 4, 5, a, b, {k, 1}, {k, 2}, <<"x">>, "y", 2.5, 1.0, 3.0, {k, 1.0}, [1], [1.0]],
    Key = fun(R) -> lists:nth(R rem length(Keys) + 1, Keys) end,
    Rand0 = rand:seed_s(exsss, {11, 12, 13}),
    lists:foldl(
        fun(N, Rand) ->
            {R, Rand1} = rand:uniform_s(1 bsl 30, Rand),
            K = Key(R bsr 8),
            {F, Args} =
                case R rem 16 of
                    0 -> {insert, [{K, N}]};
                    1 -> {insert, [[{K, N, a}, {Key(R bsr 12), N, b}]]};
                    2 -> {insert_new, [{K, N}]};
                    3 -> {delete, [K]};
                    4 -> {lookup, [K]};
                    5 -> {member, [K]};
                    6 -> {take, [K]};
                    7 -> {next, [K]};
                    8 -> {prev, [K]};
                    9 -> {first, []};
                    10 -> {last, []};
                    11 -> {select, [[{{'$1', '$2'}, [{'>', '$2', N div 2}], ['$1']}]]};
                    12 -> {match_object, [{'_', '_', a}]};
                    13 -> {select_delete, [[{{'$1', '$2', b}, [], [true]}]]};
                    14 -> {delete_object, [{K, N - 1}]};
                    15 -> {tab2list, []}
                end,
            %% The comparison is `=:=', so 1 and 1.0 are different results.
            Expected = apply(ets, F, [E | Args]),
            Actual = apply(etx, F, [T | Args]),
            ?assert(Expected =:= Actual, {N, F, Args, Expected, Actual}),
            Rand1
        end,
        Rand0,
        lists:seq(1, 600)
    ),
    ?assert(ets:tab2list(E) =:= etx:tab2list(T)),
    true = ets:delete(E).

%% `transaction/2' with one table and with two tables.
transactions() ->
    A = etx:open(name()),
    B = etx:open(name()),
    true = etx:insert(A, [{alice, 10}, {bob, 5}]),
    ok = etx:transaction(A, fun(Tx) ->
        [{alice, X}] = etx:lookup(Tx, alice),
        [{bob, Y}] = etx:lookup(Tx, bob),
        true = etx:insert(Tx, [{alice, X - 3}, {bob, Y + 3}]),
        %% A read returns the writes of the transaction.
        ?assertEqual([{alice, 7}, {bob, 8}], etx:tab2list(Tx)),
        ?assertEqual([bob], etx:select(Tx, [{{'$1', '$2'}, [{'>', '$2', 7}], ['$1']}])),
        ?assertEqual(bob, etx:next(Tx, alice)),
        %% Another process does not see them before the commit.
        Parent = self(),
        spawn(fun() -> Parent ! {seen, etx:tab2list(A)} end),
        receive
            {seen, Seen} -> ?assertEqual([{alice, 10}, {bob, 5}], Seen)
        end,
        ok
    end),
    ?assertEqual([{alice, 7}, {bob, 8}], etx:tab2list(A)),
    %% Two tables in one transaction.
    moved = etx:transaction([A, B], fun([TxA, TxB]) ->
        [Object] = etx:take(TxA, alice),
        true = etx:insert(TxB, Object),
        9 = etx:update_counter(TxA, bob, 1),
        moved
    end),
    ?assertEqual([{bob, 9}], etx:tab2list(A)),
    ?assertEqual([{alice, 7}], etx:tab2list(B)),
    %% A transaction whose function fails writes nothing.
    ?assertError(stop, etx:transaction([A, B], fun([TxA, TxB]) ->
        true = etx:delete_all_objects(TxA),
        true = etx:insert(TxB, {carol, 1}),
        error(stop)
    end)),
    ?assertEqual([{bob, 9}], etx:tab2list(A)),
    ?assertEqual([{alice, 7}], etx:tab2list(B)),
    %% A transaction in a transaction is one transaction.
    ok = etx:transaction(A, fun(Tx) ->
        etx:transaction(Tx, fun(Inner) ->
            true = etx:insert(Inner, {dave, 1}),
            ok
        end)
    end),
    ?assertEqual([{bob, 9}, {dave, 1}], etx:tab2list(A)),
    ?assertError(badarg, etx:transaction([A, etx:open(name(), [{cluster, second}])], fun(_) -> ok end)).

%% 8 processes change one object 50 times each, half of them with
%% `update_counter/3' and half of them with a read and a write in
%% `transaction/2'. No change is lost. 4 processes move amounts between
%% two accounts, and the sum of the two accounts stays the same.
concurrent() ->
    T = etx:open(name()),
    true = etx:insert(T, [{counter, 0}, {left, 1000}, {right, 1000}]),
    Parent = self(),
    Counters = [
        spawn_link(fun() ->
            lists:foreach(
                fun(_) ->
                    case I rem 2 of
                        0 ->
                            _ = etx:update_counter(T, counter, 1);
                        1 ->
                            etx:transaction(T, fun(Tx) ->
                                [{counter, Value}] = etx:lookup(Tx, counter),
                                true = etx:insert(Tx, {counter, Value + 1})
                            end)
                    end
                end,
                lists:seq(1, 50)
            ),
            Parent ! {done, self()}
        end)
     || I <- lists:seq(1, 8)
    ],
    Movers = [
        spawn_link(fun() ->
            lists:foreach(
                fun(N) ->
                    etx:transaction(T, fun(Tx) ->
                        [{left, Left}] = etx:lookup(Tx, left),
                        [{right, Right}] = etx:lookup(Tx, right),
                        Amount = (N * I) rem 7 - 3,
                        true = etx:insert(Tx, [{left, Left - Amount}, {right, Right + Amount}])
                    end),
                    %% A read of the two accounts in one transaction.
                    [{left, L}, {right, R}] = etx:select(T, [{{'$1', '$2'}, [{'=/=', '$1', counter}], ['$_']}]),
                    2000 = L + R
                end,
                lists:seq(1, 50)
            ),
            Parent ! {done, self()}
        end)
     || I <- lists:seq(1, 4)
    ],
    [
        receive
            {done, Pid} -> ok
        after 100000 -> error(timeout)
        end
     || Pid <- Counters ++ Movers
    ],
    ?assertEqual([{counter, 400}], etx:lookup(T, counter)),
    ?assertEqual(2000, etx:lookup_element(T, left, 2) + etx:lookup_element(T, right, 2)).

%% Two clusters have two tables with one name.
two_clusters() ->
    Name = name(),
    First = etx:open(Name, [{cluster, default}]),
    Second = etx:open(Name, [{cluster, second}, {keypos, 2}]),
    true = etx:insert(First, {a, 1}),
    true = etx:insert(Second, {x, b}),
    ?assertEqual([{a, 1}], etx:tab2list(First)),
    ?assertEqual([{x, b}], etx:tab2list(Second)),
    ?assertEqual(second, etx:info(Second, cluster)),
    ?assertEqual(1, etx:info(First, keypos)),
    ?assertEqual(2, etx:info(Second, keypos)).

%% The application stops and starts again. A cluster of one node starts
%% without the tables of the earlier run, because a table is in memory.
restart() ->
    Name = name(),
    T = etx:open(Name),
    true = etx:insert(T, {a, 1}),
    ok = application:stop(etx),
    ?assertEqual([], etx:clusters()),
    ?assertError(badarg, etx:lookup(T, a)),
    {ok, _} = application:ensure_all_started(etx),
    ?assertEqual([], etx:tab2list(etx:open(Name))),
    true = etx:insert(T, {b, 2}),
    ?assertEqual([{b, 2}], etx:tab2list(T)).
