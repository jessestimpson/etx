-module(etx_nodes_tests).

-include_lib("eunit/include/eunit.hrl").

%% The test starts three Erlang nodes on this computer with `peer'. Each
%% node runs the etx application with one cluster, and the three nodes
%% have the same list of three coordinators. The test starts Erlang
%% distribution with a short name, which needs `epmd'.
three_nodes_test_() ->
    {timeout, 120, fun three_nodes/0}.

three_nodes() ->
    ok = distribute(),
    Args = ["-setcookie", atom_to_list(erlang:get_cookie()), "-pa" | [Path || Path <- code:get_path(), filelib:is_dir(Path)]],
    Peers = [
        begin
            {ok, Peer, Node} = peer:start_link(#{name => peer:random_name(), connection => standard_io, args => Args}),
            {Peer, Node}
        end
     || _ <- [1, 2, 3]
    ],
    [{P1, _N1}, {P2, _N2}, {P3, N3}] = Peers,
    Coordinators = [{etx_test_coordinator, Node} || {_Peer, Node} <- Peers],
    Base = filename:join([filename:basedir(user_cache, "etx_test"), "nodes", integer_to_list(erlang:unique_integer([positive]))]),
    try
        lists:foreach(
            fun({Peer, Node}) ->
                Cluster = #{coordinators => Coordinators, dir => filename:join(Base, atom_to_list(Node)), fresh => true},
                ok = peer:call(Peer, application, set_env, [etx, clusters, #{default => Cluster}, [{persistent, true}]]),
                {ok, _} = peer:call(Peer, application, ensure_all_started, [etx])
            end,
            Peers
        ),
        %% A table that one node opens is a table of every node. The
        %% handle of one node is a handle on another node.
        T = peer:call(P1, etx, open, [accounts], 30000),
        true = peer:call(P1, etx, insert, [T, [{alice, 10}, {counter, 0}]]),
        ?assertEqual([{alice, 10}], peer:call(P2, etx, lookup, [T, alice])),
        ?assertEqual([{alice, 10}], peer:call(P3, etx, lookup, [peer:call(P3, etx, open, [accounts]), alice])),
        true = peer:call(P3, etx, insert, [T, {bob, 5}]),
        ?assertEqual([{alice, 10}, {bob, 5}, {counter, 0}], peer:call(P1, etx, tab2list, [T])),
        %% Processes of the three nodes change one object. No change is
        %% lost.
        Parent = self(),
        Workers = [
            spawn_link(fun() ->
                [peer:call(Peer, etx, update_counter, [T, counter, 1], 30000) || _ <- lists:seq(1, 30)],
                Parent ! {done, self()}
            end)
         || {Peer, _Node} <- Peers
        ],
        [
            receive
                {done, Worker} -> ok
            after 60000 -> error(timeout)
            end
         || Worker <- Workers
        ],
        ?assertEqual([{counter, 90}], peer:call(P2, etx, lookup, [T, counter])),
        %% The cluster is healthy: one node can stop, and each node is
        %% safe to stop.
        Nodes = lists:sort([Node || {_Peer, Node} <- Peers]),
        Healthy = await_status(P1, fun(#{healthy := H}) -> H end),
        ?assertMatch(
            #{
                epoch := 1,
                generation := 0,
                problems := [],
                coordinators := #{total := 3, up := 3, majority := 2},
                storages := #{total := 3, up := 3, current := 3},
                workers := #{registered := 3, min := 2},
                fault_tolerance := #{
                    max_node_failures_without_losing_data := 1,
                    max_node_failures_without_losing_availability := 1,
                    safe_to_stop := Nodes
                }
            },
            Healthy
        ),
        ?assertEqual(Nodes, lists:sort(maps:keys(maps:get(nodes, Healthy)))),
        %% One node stops. The two other nodes have a majority of the
        %% coordinators, and each record of the log is on 2 LogServers.
        %% The cluster starts a new epoch, and a function waits for it.
        ok = peer:stop(P3),
        ?assertEqual(pang, net_adm:ping(N3)),
        ?assertEqual(91, peer:call(P1, etx, update_counter, [T, counter, 1], 60000)),
        %% With two of three nodes, the cluster has a new epoch and is not
        %% healthy. No further node can stop: the two coordinators that
        %% run are the majority.
        Degraded = await_status(P2, fun(#{epoch := Epoch}) -> Epoch =:= 2 end),
        ?assertMatch(
            #{
                healthy := false,
                coordinators := #{up := 2},
                storages := #{up := 2, current := 2},
                fault_tolerance := #{max_node_failures_without_losing_availability := 0, safe_to_stop := []}
            },
            Degraded
        ),
        ?assert(lists:member({coordinator_down, N3}, maps:get(problems, Degraded))),
        ?assert(lists:member({storage_down, N3}, maps:get(problems, Degraded))),
        ?assertMatch(#{coordinator := down, storage := down}, maps:get(N3, maps:get(nodes, Degraded))),
        ?assertEqual([{alice, 10}, {bob, 5}, {counter, 91}], peer:call(P2, etx, tab2list, [T], 60000)),
        true = peer:call(P2, etx, insert, [T, {carol, 1}], 60000),
        ?assertEqual([{carol, 1}], peer:call(P1, etx, lookup, [T, carol], 60000))
    after
        [catch peer:stop(Peer) || {Peer, _Node} <- Peers],
        _ = file:del_dir_r(Base)
    end.

%% Every node of a cluster of three nodes stops and starts again, with the
%% directories of the coordinators as they are. The nodes form the same
%% cluster, and the cluster starts again without its tables.
full_restart_test_() ->
    {timeout, 180, fun full_restart/0}.

full_restart() ->
    ok = distribute(),
    Args = ["-setcookie", atom_to_list(erlang:get_cookie()), "-pa" | [Path || Path <- code:get_path(), filelib:is_dir(Path)]],
    Tag = integer_to_list(erlang:unique_integer([positive])),
    Names = [list_to_atom(lists:concat([etx_restart_, Tag, "_", N])) || N <- [1, 2, 3]],
    Base = filename:join([filename:basedir(user_cache, "etx_test"), "restart", Tag]),
    Start = fun() ->
        Peers = [
            begin
                {ok, Peer, Node} = peer:start_link(#{name => Name, connection => standard_io, args => Args}),
                {Peer, Node}
            end
         || Name <- Names
        ],
        Cluster = #{coordinators => [{etx_test_coordinator, Node} || {_Peer, Node} <- Peers], dir => Base},
        lists:foreach(
            fun({Peer, _Node}) ->
                ok = peer:call(Peer, application, set_env, [etx, clusters, #{default => Cluster}, [{persistent, true}]]),
                {ok, _} = peer:call(Peer, application, ensure_all_started, [etx])
            end,
            Peers
        ),
        Peers
    end,
    First = [{P1, _} | _] = Start(),
    try
        T = peer:call(P1, etx, open, [accounts], 60000),
        true = peer:call(P1, etx, insert, [T, [{alice, 10}, {bob, 5}]], 60000),
        #{epoch := Epoch1} = await_status(P1, fun(#{healthy := Healthy}) -> Healthy end),
        %% Every node stops.
        [ok = peer:stop(Peer) || {Peer, _Node} <- First],
        %% The nodes start again with the same names and the same
        %% directories. The coordinated state has the cluster and its last
        %% epoch, whose LogServers do not run.
        Second = [{Q1, _}, {Q2, _}, {Q3, _}] = Start(),
        try
            T2 = peer:call(Q1, etx, open, [accounts], 60000),
            ?assertEqual([], peer:call(Q1, etx, tab2list, [T2], 60000)),
            true = peer:call(Q2, etx, insert, [T2, {carol, 1}], 60000),
            ?assertEqual([{carol, 1}], peer:call(Q3, etx, tab2list, [T2], 60000)),
            %% The cluster is healthy again, with a later epoch.
            Status = await_status(Q3, fun(#{healthy := Healthy}) -> Healthy end),
            ?assert(maps:get(epoch, Status) > Epoch1, {Epoch1, Status}),
            %% The status reports the reset of the database.
            ?assertEqual(1, maps:get(generation, Status)),
            ?assertMatch(#{storages := #{total := 3, current := 3}, fault_tolerance := #{max_node_failures_without_losing_availability := 1}}, Status)
        after
            [catch peer:stop(Peer) || {Peer, _Node} <- Second]
        end
    after
        [catch peer:stop(Peer) || {Peer, _Node} <- First],
        _ = file:del_dir_r(Base)
    end.

%% Asks `etx:status/0' on a node until `Done' is true for the result.
await_status(Peer, Done) ->
    await_status(Peer, Done, 100).

await_status(Peer, _Done, 0) ->
    error({status, peer:call(Peer, etx, status, [])});
await_status(Peer, Done, Attempts) ->
    Status = peer:call(Peer, etx, status, [], 30000),
    case Done(Status) of
        true ->
            Status;
        false ->
            timer:sleep(100),
            await_status(Peer, Done, Attempts - 1)
    end.

distribute() ->
    _ = os:cmd("epmd -daemon"),
    Name = list_to_atom("etx_test_" ++ os:getpid()),
    case net_kernel:start(Name, #{name_domain => shortnames}) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.
