%% This module is the eta harness for etx. The harness starts etx on three
%% simulated nodes, runs clients that call the functions of `etx' on every
%% node, injects faults, and checks invariants after every step.
%%
%% == Simulated system ==
%%
%% <ul>
%% <li>Three simulated nodes: `n1', `n2' and `n3'. Each node runs the
%%   supervisor of the etx application (`etx_sup'), which starts the
%%   processes of the cluster `default' from the environment of the
%%   application, as in a deployment: a coordinator, the process that
%%   forms the peace cluster, a worker with a candidate for the
%%   ClusterController, and a StorageServer.</li>
%% <li>etx, redwall and peace are compiled with the parse transform of
%%   eta. The run has the simulated network and the simulated disk of
%%   eta. A coordinator keeps its data on the simulated disk.</li>
%% <li>An application cannot start in a run of eta. A process of the
%%   harness starts `etx_sup' on each node in its place.</li>
%% <li>The clients run on the three nodes. A client reads from the
%%   StorageServer of its node.</li>
%% </ul>
%%
%% == Workload ==
%%
%% <ul>
%% <li>`boot': the first operation. It starts etx on the three nodes, and
%%   a client that creates the table with 4 accounts and a counter. A
%%   client that starts before the table exists waits for it.</li>
%% <li>`{client, R1, R2}': a client on the node that `R1' selects runs one
%%   operation of `etx_dst_client:op/3': a transfer between two accounts
%%   in one transaction, a read of the accounts, a count with
%%   `update_counter/3', or a read of the counter.</li>
%% <li>`kill': kill the node `victim' of the run. The kill stops every
%%   process of the node, and is a crash of the disk of the node.</li>
%% <li>`restart': start etx on the killed node again. The coordinator
%%   reads its data from the disk. The StorageServer starts without data
%%   and reads every record from the LogServers.</li>
%% <li>`{partition, R1, R2}': cut the connection between two nodes.</li>
%% <li>`heal': remove every cut.</li>
%% </ul>
%%
%% After the last operation, the harness removes every cut, starts etx on
%% the killed node, stops the loss of messages, and starts one last client
%% on each node (`etx_dst_client:final/2'). The run continues until
%% `check_final/2' holds, for at most the settle steps of the run.
%%
%% With the config `restart_at => N', the operation `N' first stops every
%% node and starts every node again (`restart_all/1'). The cluster starts
%% again without its tables, and a client creates the table of the run
%% again.
%%
%% == The node that is killed ==
%%
%% A run kills one node only, the `victim', any number of times. The seed
%% selects the victim. A LogServer of redwall keeps its records in
%% memory, and each record is on 2 LogServers of its epoch, on 2 nodes.
%% After kills of two different nodes, also with a restart in between, a
%% record of an earlier epoch can be on no LogServer. A StorageServer that
%% starts after that cannot read the record. See `docs/limitations.md'.
%%
%% With the config `rolling => true', the victim changes after each
%% restart, so a run kills two or three different nodes, one at a time.
%% A process on another node then asks `etx:status/0', and kills the node
%% only if the cluster is healthy and the node is in `safe_to_stop': an
%% operator restarts the next node after the cluster has recovered from
%% the restart before it. The runs therefore also check that the answer
%% of `etx:status/0' is a sufficient condition for the stop of a node. A StorageServer that
%% starts again copies the data from the StorageServer of another node,
%% so it does not need the records of the LogServers that are lost.
%%
%% == One node alone ==
%%
%% With the config `alone => true', a run stops two of the three nodes, one
%% at a time, and starts them again, one at a time:
%%
%% <ol>
%% <li>A process on another node asks `etx:status/0', and the harness
%%   kills the first node if the cluster is healthy and the node is in
%%   `safe_to_stop'.</li>
%% <li>A process on the third node asks `etx:status/0'. The harness kills
%%   the second node if the cluster has a later epoch than at the first
%%   kill, every LogServer of that epoch runs, and the StorageServers of
%%   the two nodes that run are current. The status does not list the
%%   second node as safe to stop, because the cluster is not available
%%   with one node.</li>
%% <li>The third node runs alone. It has 1 of 3 coordinators, so the
%%   cluster has no epoch, and a client on that node waits. The node has
%%   the data in its StorageServer and in its LogServer of the last
%%   epoch.</li>
%% <li>A `restart' operation starts one of the two killed nodes, and the
%%   next `restart' operation starts the other. The seed selects the
%%   order.</li>
%% </ol>
%%
%% The recovery after step 4 finds 1 of the 2 LogServers of the last epoch
%% lost, which is below the replication degree of 2, so it does not reset
%% the database. `check_final/2' checks that the last client of each node
%% reads the accounts and every earlier write.
%%
%% The planted defect `alone_no_wait': the harness kills the second node
%% without the question of step 2. The cluster can then lose 2 LogServers
%% of one epoch.
%%
%% == Invariants ==
%%
%% The harness checks these invariants after every step:
%%
%% <ul>
%% <li>`conservation' - each read of the 4 accounts in one transaction has
%%   the sum of the accounts at the start. A transfer moves an amount in
%%   one transaction, so a read that sees a part of a transfer has another
%%   sum.</li>
%% <li>`counter_unique' - no two calls of `update_counter/3' return the
%%   same value.</li>
%% <li>`counter_order' - a call of `update_counter/3' that starts after
%%   the end of another call, on any node, returns a higher value. This is
%%   strict serializability for the counter.</li>
%% <li>`stale_read' - a read of the counter returns at least the value of
%%   every call of `update_counter/3' that ended before the read
%%   started.</li>
%% <li>`at_most_once' - no transaction is applied a second time after its
%%   commit. A transfer inserts an object with the number of its
%%   operation, and finds the object in a second application. No call of
%%   `update_counter/3' returns a value above the number of calls that
%%   have started. etx has this property through the idempotency ids of
%%   redwall.</li>
%% </ul>
%%
%% `check_final/2' checks at the end of a run:
%%
%% <ul>
%% <li>`final' - the last client of each of the three nodes has ended: its
%%   count and its read of every object, and `etx:status/0' has reported
%%   the StorageServer of its node as current. This is a check of
%%   availability after the faults.</li>
%% <li>`conservation' - the read of each last client has the sum of the
%%   accounts at the start.</li>
%% <li>`durable' - the read of each last client has every object of a
%%   write without a read that ended before the read started.</li>
%% </ul>
%%
%% == Planted defects ==
%%
%% The config key `mode' selects a defect:
%%
%% <ul>
%% <li>`split_transfer' - a transfer writes the two accounts in two
%%   transactions. This defect violates `conservation'.</li>
%% <li>`lost_update' - a count reads the counter in one transaction and
%%   writes it in another. This defect violates `counter_unique'.</li>
%% <li>`no_copy' - the cluster has the option `storage_copy => false'. A
%%   StorageServer that starts again reads every record from the
%%   LogServers. With the config `rolling', a run ends with a node that
%%   does not answer.</li>
%% <li>`no_status' - with the config `rolling', the harness kills a node
%%   without a question to `etx:status/0'. A second node then stops
%%   before the cluster has recovered from the stop of the first. The
%%   cluster loses 2 LogServers of one epoch and resets the database, so
%%   a read does not find the accounts.</li>
%% <li>`no_reset' - the cluster has the option
%%   `reset_after_log_loss => false'. With the config `restart_at', the
%%   cluster has no epoch after the restart of every node, and a run ends
%%   with nodes that do not answer.</li>
%% <li>`no_idempotency' - the cluster has the option
%%   `automatic_idempotency => false'. When the process of an epoch stops
%%   after a commit is durable and before the client has the answer, the
%%   client runs the transaction again. This defect violates
%%   `at_most_once'.</li>
%% </ul>
%%
%% == Limitations ==
%%
%% <ul>
%% <li>The run kills one of the three nodes only. See "The node that is
%%   killed".</li>
%% <li>A run stops every node at most once, at an operation that the
%%   test names.</li>
%% <li>The run has one cluster and one table.</li>
%% <li>A client calls 6 functions of `etx': `open/1', `insert_new/2',
%%   `lookup/2', `insert/2', `tab2list/1', `select/2', `update_counter/3'
%%   and `lookup_element/3', and `transaction/2'. The unit tests compare
%%   the other functions with `ets'.</li>
%% <li>The application controller is not in the run.</li>
%% </ul>
-module(etx_dst).

-behaviour(eta_harness).

-export([init/2, processes/1, generate/2, execute/2, check/1, check_final/2, settle_done/1, terminate/1]).
-export([stats/0, reset_stats/0]).

-define(STATS, etx_dst_stats).
-define(NODES, [n1, n2, n3]).

%% ---------------------------------------------------------------------------
%% eta_harness
%% ---------------------------------------------------------------------------

init(Seed, Config) ->
    {module, _} = code:ensure_loaded(etx_dst_client),
    Tab = ets:new(etx_dst, [public, ordered_set]),
    ok = clear_dir(disk_dir()),
    %% The clusters of the application environment. Every node has the
    %% same configuration.
    _ = application:load(etx),
    ok = application:set_env(etx, clusters, #{
        default => #{
            coordinators => [{etx_dst_coordinator, Node} || Node <- ?NODES],
            dir => disk_dir(),
            %% The planted defect `no_idempotency'.
            automatic_idempotency => maps:get(mode, Config, correct) =/= no_idempotency,
            %% The planted defect `no_copy'.
            storage_copy => maps:get(mode, Config, correct) =/= no_copy,
            %% The planted defect `no_reset'.
            reset_after_log_loss => maps:get(mode, Config, correct) =/= no_reset
        }
    }),
    [ok = eta_net:place(Node, []) || Node <- ?NODES],
    [true = eta_net:with_node(A, fun() -> eta_net:connect_node(B) end) || A <- ?NODES, B <- ?NODES, A < B],
    {ok, #{
        tab => Tab,
        mode => maps:get(mode, Config, correct),
        faults => maps:get(faults, Config, true),
        %% Whether the run kills another node after each restart.
        rolling => maps:get(rolling, Config, false),
        %% Whether the run stops two nodes, one at a time. See "One node
        %% alone". The first two nodes of `alone_order' are the nodes
        %% that the run kills, in the order of the kills. `alone_first'
        %% is the node that starts again first.
        alone => maps:get(alone, Config, false),
        alone_order => lists:nth(Seed rem 6 + 1, [[A, B, C] || A <- ?NODES, B <- ?NODES, C <- ?NODES, A =/= B, B =/= C, A =/= C]),
        alone_first => Seed div 6 rem 2 + 1,
        %% The number of the operation that stops every node and starts
        %% every node again, or `undefined'.
        restart_at => maps:get(restart_at, Config, undefined),
        %% The only node that the run kills.
        victim => lists:nth(Seed rem length(?NODES) + 1, ?NODES),
        last_op => maps:get(last_op, Config, undefined),
        ops => [],
        n => 0
    }}.

processes(#{ops := Ops}) ->
    [Pid || Pid <- Ops, is_process_alive(Pid)].

generate(#{n := 0}, Rand) ->
    {boot, Rand};
generate(#{faults := Faults, rolling := Rolling0, alone := Alone}, Rand0) ->
    %% A run with one node alone has the operations of a run with the
    %% config `rolling'.
    Rolling = Rolling0 orelse Alone,
    {Roll, Rand1} = rand:uniform_s(Rand0),
    {R1, Rand2} = rand:uniform_s(1000, Rand1),
    {R2, Rand3} = rand:uniform_s(100000, Rand2),
    Op =
        if
            not Faults -> {client, R1, R2};
            %% With the config `rolling', a kill waits for a recovered
            %% cluster, so the kills and the restarts are more frequent,
            %% and the run has no partition: a node that is cut off keeps
            %% the cluster from the state in which the next node is
            %% killed.
            Rolling, Roll < 0.60 -> {client, R1, R2};
            Rolling, Roll < 0.80 -> kill;
            Rolling -> restart;
            Roll < 0.86 -> {client, R1, R2};
            Roll < 0.91 -> kill;
            Roll < 0.96 -> restart;
            Roll < 0.985 -> {partition, R1, R2};
            true -> heal
        end,
    {Op, Rand3}.

execute(Op, S0 = #{n := N0, tab := Tab}) ->
    %% A kill that `etx:status/0' has approved. See `kill_if_safe/2' of
    %% `etx_dst_client'.
    _ =
        case {ets:take(Tab, kill_approved), ets:member(Tab, down)} of
            {[{kill_approved, Victim}], false} -> etx_dst_client:kill(Tab, Victim);
            _ -> ok
        end,
    %% The kills of a run with one node alone, which a process of the run
    %% has approved.
    _ =
        case ets:take(Tab, alone_approved) of
            [{alone_approved, Step, Node}] -> alone_kill(Tab, Step, Node);
            [] -> ok
        end,
    N = N0 + 1,
    S1 =
        case S0 of
            #{restart_at := N} -> restart_all(S0);
            _ -> S0
        end,
    S = execute(Op, N, S1#{n := N}),
    case S of
        #{last_op := N} -> repair(S);
        _ -> S
    end.

%% Stops every node, and starts every node again. A kill is a crash of the
%% disk of the node. The coordinators read the coordinated state from
%% their disks, and no LogServer of the last epoch runs, so the recovery
%% resets the database. The tables of the time before are lost. The
%% harness therefore removes its records of the calls of that time, and a
%% client creates the table of the run again. The invariants then hold
%% for the calls after the restart.
restart_all(S = #{tab := Tab, victim := Victim}) ->
    [ok = eta_net:kill_node(Node) || Node <- ?NODES],
    [true = ets:delete(Tab, Key) || Key <- [ready, down, kill_approved, counter_checked]],
    [
        true = ets:match_delete(Tab, {{Kind, '_'}, '_'})
     || Kind <- [started, count, count_started, count_read, note, final]
    ],
    true = ets:match_delete(Tab, {{final, '_'}, '_', '_'}),
    bump(restarts_of_every_node),
    S1 = lists:foldl(fun(Node, Acc) -> start_node(Node, Acc) end, S, ?NODES),
    spawn_op(hd(?NODES -- [Victim]), fun() -> etx_dst_client:setup(Tab) end, S1).

execute(boot, _N, S = #{tab := Tab}) ->
    S1 = lists:foldl(fun(Node, Acc) -> start_node(Node, Acc) end, S, ?NODES),
    %% The client that creates the table runs on a node that the run
    %% does not kill.
    spawn_op(hd(?NODES -- [maps:get(victim, S)]), fun() -> etx_dst_client:setup(Tab) end, S1);
execute({client, R1, R2}, N, S = #{tab := Tab, mode := Mode}) ->
    %% A client runs on a node that is not killed.
    Node = pick(R1, running(S)),
    bump(clients),
    spawn_op(Node, fun() -> client(Tab, N, R2, Mode) end, S);
execute(kill, _N, S = #{tab := Tab, alone := true, alone_order := [First, Second, Third], mode := Mode}) ->
    case {ets:member(Tab, ready), ets:lookup(Tab, alone_step)} of
        {true, []} ->
            %% The first kill, with the approval of `etx:status/0'.
            spawn_op(Second, fun() -> etx_dst_client:alone_first(Tab, First) end, S);
        {true, [{alone_step, 1}]} when Mode =:= alone_no_wait ->
            %% The planted defect: the second kill without a question.
            ok = alone_kill(Tab, 2, Second),
            S;
        {true, [{alone_step, 1}]} ->
            spawn_op(Third, fun() -> etx_dst_client:alone_second(Tab, First, Second) end, S);
        _ ->
            S
    end;
execute(restart, _N, S = #{tab := Tab, alone := true, alone_order := [First, Second, _Third], alone_first := Pick}) ->
    Order =
        case Pick of
            1 -> [First, Second];
            2 -> [Second, First]
        end,
    case ets:lookup(Tab, alone_step) of
        [{alone_step, Step}] when Step =:= 2; Step =:= 3 ->
            Node = lists:nth(Step - 1, Order),
            true = ets:delete(Tab, {alone_down, Node}),
            true = ets:insert(Tab, {alone_step, Step + 1}),
            bump(restarts),
            start_node(Node, S);
        _ ->
            S
    end;
execute(kill, _N, S = #{tab := Tab, victim := Victim, rolling := Rolling}) ->
    case {ets:member(Tab, down), Rolling} of
        {true, _} ->
            S;
        {false, false} ->
            %% The victim is killed at any time, also during the start of
            %% the cluster. The client that creates the table runs on
            %% another node.
            ok = etx_dst_client:kill(Tab, Victim),
            S;
        {false, true} ->
            %% With the config `rolling', a process on another node asks
            %% `etx:status/0', and kills the node only if the cluster is
            %% healthy and the node is safe to stop. An operator who
            %% restarts the nodes one after another does the same.
            case {ets:member(Tab, ready), maps:get(mode, S)} of
                {true, no_status} ->
                    %% The planted defect: the node is killed without a
                    %% question to `etx:status/0'.
                    ok = etx_dst_client:kill(Tab, Victim),
                    S;
                {true, _} ->
                    spawn_op(hd(?NODES -- [Victim]), fun() -> etx_dst_client:kill_if_safe(Tab, Victim) end, S);
                {false, _} ->
                    S
            end
    end;
execute(restart, N, S = #{tab := Tab}) ->
    case ets:lookup(Tab, down) of
        [{down, Node}] ->
            true = ets:delete(Tab, down),
            bump(restarts),
            S1 = start_node(Node, S),
            %% With the config `rolling', the next kill is a kill of
            %% another node.
            case S1 of
                #{rolling := true} -> S1#{victim := lists:nth(N rem 2 + 1, ?NODES -- [Node])};
                _ -> S1
            end;
        [] ->
            S
    end;
execute({partition, R1, R2}, _N, S) ->
    case {pick(R1, ?NODES), pick(R2, ?NODES)} of
        {A, A} ->
            S;
        {A, B} ->
            ok = eta_net:partition(A, B),
            bump(partitions),
            S
    end;
execute(heal, _N, S) ->
    ok = eta_net:heal_all(),
    S.

%% After the last operation, the harness removes every cut, starts etx on
%% the killed node, and stops the loss of messages. It then starts the
%% last client of each node.
repair(S0 = #{tab := Tab}) ->
    ok = eta_net:heal_all(),
    ok = eta_net:set_policy((eta_net:policy())#{drop_p => 0.0}),
    S1 =
        case ets:take(Tab, down) of
            [{down, Node}] -> start_node(Node, S0);
            [] -> S0
        end,
    %% The killed nodes of a run with one node alone.
    S2 = lists:foldl(
        fun([Node], Acc) ->
            true = ets:delete(Tab, {alone_down, Node}),
            start_node(Node, Acc)
        end,
        S1,
        lists:sort(ets:match(Tab, {{alone_down, '$1'}, '_'}))
    ),
    lists:foldl(fun(Node, Acc) -> spawn_op(Node, fun() -> final(Tab) end, Acc) end, S2, ?NODES).

%% Kills a node in a run with one node alone. `Step' is 1 for the first
%% kill and 2 for the second.
alone_kill(Tab, Step, Node) ->
    case ets:lookup(Tab, alone_step) of
        Rows when Step =:= 1, Rows =:= []; Step =:= 2, Rows =:= [{alone_step, 1}] ->
            true = ets:insert(Tab, [{alone_step, Step}, {{alone_down, Node}, true}, {{killed, Node}, true}]),
            true = ets:delete(Tab, {started, Node}),
            _ = ets:update_counter(Tab, kills, 1, {kills, 0}),
            ok = eta_net:kill_node(Node);
        _OtherStep ->
            ok
    end.

%% The last client waits for the table of the run, and for the start of
%% etx on its node.
final(Tab) ->
    case {ets:lookup(Tab, ready), ets:member(Tab, {started, eta_net:local_node()})} of
        {[{ready, T}], true} ->
            etx_dst_client:final(Tab, T);
        _ ->
            ok = eta_time:sleep(50),
            final(Tab)
    end.

%% The operation of a client, with the planted defect of `Mode'.
client(Tab, N, R, Mode) when Mode =:= correct; Mode =:= no_idempotency; Mode =:= no_copy; Mode =:= no_status; Mode =:= no_reset; Mode =:= alone_no_wait ->
    etx_dst_client:op(Tab, N, R);
client(Tab, N, R, Mode) ->
    case {ets:lookup(Tab, ready), Mode, R rem 10} of
        {[{ready, T}], split_transfer, Transfer} when Transfer < 4 ->
            %% The planted defect: two transactions for one transfer.
            Accounts = etx_dst_client:accounts(),
            From = lists:nth((R div 10) rem 4 + 1, Accounts),
            To = lists:nth((R div 40) rem 4 + 1, Accounts),
            case From =:= To of
                true ->
                    ok;
                false ->
                    _ = etx:update_counter(T, From, -1),
                    _ = etx:update_counter(T, To, 1),
                    ok
            end;
        {[{ready, T}], lost_update, Count} when Count >= 6, Count < 9 ->
            %% The planted defect: a read and a write in two transactions.
            Start = ets:update_counter(Tab, stamp, 1, {stamp, 0}),
            true = ets:insert(Tab, {{count_started, N}, node()}),
            Value = etx:lookup_element(T, counter, 2) + 1,
            true = etx:insert(T, {counter, Value}),
            End = ets:update_counter(Tab, stamp, 1, {stamp, 0}),
            true = ets:insert(Tab, {{count, N}, #{node => node(), start => Start, 'end' => End, value => Value}});
        _ ->
            etx_dst_client:op(Tab, N, R)
    end.

check(#{tab := Tab}) ->
    first_violation([
        fun() -> conservation(Tab) end,
        fun() -> counter(Tab) end,
        fun() -> applied_once(Tab) end
    ]).

%% Each read of the accounts in one transaction has the sum of the
%% accounts at the start.
conservation(Tab) ->
    case ets:match(Tab, {{sum_differs, '_'}, '$1'}) of
        [] -> ok;
        [[Detail] | _] -> violation(conservation, Detail)
    end.

%% The invariants of the counter. The harness examines the calls again
%% only when a call or a read has ended since the last check.
counter(Tab) ->
    Counts = [Count || [Count] <- ets:match(Tab, {{count, '_'}, '$1'})],
    Reads = [Read || [Read] <- ets:match(Tab, {{count_read, '_'}, '$1'})],
    Seen = {length(Counts), length(Reads)},
    case ets:lookup(Tab, counter_checked) of
        [{counter_checked, Seen}] ->
            ok;
        _ ->
            true = ets:insert(Tab, {counter_checked, Seen}),
            Started = ets:select_count(Tab, [{{{count_started, '_'}, '_'}, [], [true]}]),
            Values = [Value || #{value := Value} <- Counts],
            first_violation([
                fun() ->
                    case Values -- lists:usort(Values) of
                        [] -> ok;
                        [Value | _] -> violation(counter_unique, #{value => Value, calls => [Count || Count = #{value := V} <- Counts, V =:= Value]})
                    end
                end,
                fun() ->
                    case [{A, B} || A = #{'end' := End, value := Va} <- Counts, B = #{start := Start, value := Vb} <- Counts, End < Start, Va >= Vb] of
                        [] -> ok;
                        [{A, B} | _] -> violation(counter_order, #{first => A, second => B})
                    end
                end,
                fun() ->
                    case [{Count, Read} || Count = #{'end' := End, value := V} <- Counts, Read = #{start := Start, value := Seen1} <- Reads, End < Start, Seen1 < V] of
                        [] -> ok;
                        [{Count, Read} | _] -> violation(stale_read, #{call => Count, read => Read})
                    end
                end,
                fun() ->
                    case [Count || Count = #{value := Value} <- Counts, Value > Started] of
                        [] -> ok;
                        [Count | _] -> violation(at_most_once, #{call => Count, started => Started})
                    end
                end
            ])
    end.

%% No transfer is applied a second time after its commit.
applied_once(Tab) ->
    case ets:match(Tab, {{applied_twice, '$1'}, '$2'}) of
        [] -> ok;
        [[C, Node] | _] -> violation(at_most_once, #{transfer => C, node => Node})
    end.

%% The last client of each node has ended, and its read has the sum of the
%% accounts.
check_final(_Settled, #{tab := Tab, last_op := Last}) when is_integer(Last) ->
    Finals = [{Node, ets:lookup(Tab, {final, Node})} || Node <- ?NODES],
    case [Node || {Node, []} <- Finals] of
        [] ->
            Total = etx_dst_client:total(),
            Notes = ets:match(Tab, {{note, '$1'}, '$2'}),
            first_violation([
                fun() ->
                    case [{Node, Rows} || {Node, [{_, Rows, _Start}]} <- Finals, lists:sum([V || {{acct, _}, V} <- Rows]) =/= Total] of
                        [] -> ok;
                        [{Node, Rows} | _] -> violation(conservation, #{node => Node, rows => Rows, final => true})
                    end
                end,
                fun() ->
                    %% A write that ended before the read of a last client
                    %% started is in that read.
                    case [{Node, C} || {Node, [{_, Rows, Start}]} <- Finals, [C, End] <- Notes, End < Start, not lists:keymember({note, C}, 1, Rows)] of
                        [] -> ok;
                        [{Node, C} | _] -> violation(durable, #{node => Node, note => C})
                    end
                end
            ]);
        Missing ->
            violation(final, #{no_answer => Missing, counted => [Node || Node <- ?NODES, ets:member(Tab, {count, {final, Node}})], ready => ets:member(Tab, ready), nodes => [{Node, node_state(Node)} || Node <- ?NODES]})
    end;
check_final(_Settled, _State) ->
    ok.

settle_done(State = #{last_op := Last}) when is_integer(Last) ->
    check_final(settle_done, State) =:= ok;
settle_done(_State) ->
    false.

terminate(#{tab := Tab, ops := Ops}) ->
    ok = record_stats(Tab),
    %% A kill of a node stops every process of the node, also the
    %% LogServers and the processes of the epochs, which have no link to
    %% the supervisor of etx.
    [ok = eta_net:kill_node(Node) || Node <- ?NODES],
    ok = kill_all([Pid || Pid <- Ops, is_process_alive(Pid)]),
    ok = clear_dir(disk_dir()),
    catch ets:delete(Tab),
    ok.

%% ---------------------------------------------------------------------------
%% Statistics
%% ---------------------------------------------------------------------------

stats() ->
    case ets:whereis(?STATS) of
        undefined -> #{};
        _ -> maps:from_list(ets:tab2list(?STATS))
    end.

reset_stats() ->
    case ets:whereis(?STATS) of
        undefined ->
            Owner = spawn(fun() ->
                receive
                    stop -> ok
                end
            end),
            ?STATS = ets:new(?STATS, [named_table, public, {heir, Owner, none}]),
            ok;
        _ ->
            true = ets:delete_all_objects(?STATS),
            ok
    end.

bump(Key) ->
    bump(Key, 1).

bump(Key, N) ->
    case ets:whereis(?STATS) of
        undefined -> ok;
        _ -> _ = ets:update_counter(?STATS, Key, N, {Key, 0})
    end,
    ok.

record_stats(Tab) ->
    bump(runs),
    Count = fun(Pattern) -> ets:select_count(Tab, [{Pattern, [], [true]}]) end,
    bump(transfers, Count({{transfer, '_'}, '_'})),
    bump(transfers_started, Count({{transfer_started, '_'}, '_'})),
    bump(reads, Count({{read, '_'}, '_'})),
    bump(counts, Count({{count, '_'}, '_'})),
    bump(counts_started, Count({{count_started, '_'}, '_'})),
    bump(counter_reads, Count({{count_read, '_'}, '_'})),
    bump(blind_writes, Count({{note, '_'}, '_'})),
    bump(skipped, Count({{skipped, '_'}, '_'})),
    bump(node_starts, Count({{started, '_'}, '_'})),
    [
        bump(Counter, case ets:lookup(Tab, Counter) of [{Counter, Value}] -> Value; [] -> 0 end)
     || Counter <- [kills, kills_refused_by_status]
    ],
    %% The runs in which one node ran alone, and the runs in which the
    %% two killed nodes started again before the end of the operations.
    Step =
        case ets:lookup(Tab, alone_step) of
            [{alone_step, Reached}] -> Reached;
            [] -> 0
        end,
    bump(runs_with_one_node_alone, length([x || Step >= 2])),
    bump(runs_with_both_nodes_started_again, length([x || Step >= 4])),
    %% The runs that killed two or three different nodes.
    bump(runs_with_kills_of_several_nodes, length([x || Count({{killed, '_'}, '_'}) > 1])),
    ok.

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

%% The state of the processes of etx on a node, for the detail of a
%% violation: the information of the worker about the database, and the
%% version of the StorageServer. The read sends no message.
node_state(Node) ->
    eta_net:with_node(Node, fun() ->
        Storage =
            try etx_cluster:storage(default) of
                Pid when is_pid(Pid) ->
                    case is_process_alive(Pid) andalso eta_observe:read(Pid) of
                        #{version := Version} -> {Pid, Version};
                        Other -> {Pid, Other}
                    end;
                undefined ->
                    none
            catch
                error:badarg -> no_registry
            end,
        Info = redwall_worker:db_info(etx_default_worker),
        Alive = [is_process_alive(Proxy) || #{proxies := Proxies} <- [Info], Proxy <- Proxies],
        #{db_info => Info, proxy_alive => Alive, storage => Storage}
    end).

%% Starts etx on a node.
start_node(Node, S = #{tab := Tab}) ->
    spawn_op(Node, fun() -> etx_dst_client:node(Tab) end, S).

%% The nodes that are not killed.
running(#{tab := Tab}) ->
    Alone = [Node || [Node] <- ets:match(Tab, {{alone_down, '$1'}, '_'})],
    case ets:lookup(Tab, down) of
        [{down, Node}] -> (?NODES -- [Node]) -- Alone;
        [] -> ?NODES -- Alone
    end.

spawn_op(Node, Fun, S = #{ops := Ops}) ->
    Pid = eta_run:spawn_op(Fun),
    ok = eta_net:place(Node, [Pid]),
    S#{ops := Ops ++ [Pid]}.

pick(R, List) -> lists:nth(R rem length(List) + 1, List).

first_violation([]) ->
    ok;
first_violation([Check | Rest]) ->
    case Check() of
        ok -> first_violation(Rest);
        Violation -> Violation
    end.

%% Every violation has a `property' key. `eta_shrink' compares two
%% failures by this key.
violation(Property, Detail) ->
    {violation, Detail#{property => Property}}.

kill_all(Pids) ->
    Refs = [{Pid, erlang:monitor(process, Pid)} || Pid <- Pids],
    lists:foreach(fun({Pid, _Ref}) -> exit(Pid, kill) end, Refs),
    lists:foreach(
        fun({Pid, Ref}) ->
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            end
        end,
        Refs
    ).

%% The directory of the data of the coordinators. Every run uses this one
%% directory, so that the name of the directory is the same in every run.
%% The harness empties the directory before and after each run. The
%% environment variable `ETX_DST_DISK_DIR' sets the directory. `dst/run.sh'
%% gives each test a directory of its own, because the tests run at the
%% same time.
disk_dir() ->
    case os:getenv("ETX_DST_DISK_DIR") of
        false -> filename:join(filename:basedir(user_cache, "etx_dst"), "disk");
        Dir -> Dir
    end.

%% Deletes the files and the directories of a directory. The function
%% uses `prim_file', because the file server is a process that no schedule
%% controls.
clear_dir(Dir) ->
    case prim_file:list_dir(Dir) of
        {ok, Names} ->
            lists:foreach(
                fun(Name) ->
                    Path = filename:join(Dir, Name),
                    case prim_file:delete(Path) of
                        ok ->
                            ok;
                        {error, _} ->
                            ok = clear_dir(Path),
                            ok = prim_file:del_dir(Path)
                    end
                end,
                Names
            );
        {error, enoent} ->
            ok
    end.
