%% The processes that the harness `etx_dst' starts on the simulated nodes:
%% the etx supervisor of a node, and the clients.
-module(etx_dst_client).

-include("etx_eta.hrl").

-export([node/1, setup/1, op/3, final/2, kill/2, kill_if_safe/2, alone_first/2, alone_second/3]).
-export([accounts/0, total/0]).

%% The 4 accounts and their sum.
accounts() -> [{acct, I} || I <- [1, 2, 3, 4]].

total() -> 400.

%% Starts the supervisor of the etx application on the node of the caller,
%% and waits. An application cannot start in a run of eta, so this process
%% takes the place of the application. The supervisor reads the clusters
%% from the environment of the application, as in a deployment. The
%% supervisor is linked to this process, and the harness stops the node
%% with a kill of the node.
node(Tab) ->
    ?ETA_LABEL(etx_node),
    {ok, _Sup} = etx_sup:start_link(),
    true = ets:insert(Tab, {{started, node()}, true}),
    receive
        stop -> ok
    end.

%% Kills the node `Victim', and records the kill in the table of the run.
kill(Tab, Victim) ->
    true = ets:insert(Tab, [{down, Victim}, {{killed, Victim}, true}]),
    true = ets:delete(Tab, {started, Victim}),
    _ = ets:update_counter(Tab, kills, 1, {kills, 0}),
    ok = eta_net:kill_node(Victim).

%% Asks `etx:status/0' on the node of the caller. If the cluster is
%% healthy and the node `Victim' is safe to stop, the process records the
%% row `kill_approved' in the table of the run, and the harness kills the
%% node with its next operation. The harness performs the kill, because a
%% kill of a node from a process of the run waits outside the schedule.
%% The run has no other fault between the answer and the kill.
kill_if_safe(Tab, Victim) ->
    Safe =
        case etx:status() of
            #{healthy := true, fault_tolerance := #{safe_to_stop := Nodes}} -> lists:member(Victim, Nodes);
            _NotHealthy -> false
        end,
    case Safe andalso not ets:member(Tab, down) of
        true ->
            true = ets:insert(Tab, {kill_approved, Victim}),
            ok;
        false ->
            _ = ets:update_counter(Tab, kills_refused_by_status, 1, {kills_refused_by_status, 0}),
            ok
    end.

%% The first kill of a run with one node alone. See "One node alone" in
%% `etx_dst'. The process asks `etx:status/0', as `kill_if_safe/2' does,
%% and records the epoch of the cluster.
alone_first(Tab, Victim) ->
    case etx:status() of
        #{healthy := true, epoch := Epoch, fault_tolerance := #{safe_to_stop := Nodes}} ->
            case lists:member(Victim, Nodes) of
                true -> true = ets:insert(Tab, [{alone_epoch, Epoch}, {alone_approved, 1, Victim}]);
                false -> true
            end;
        _NotHealthy ->
            true
    end,
    ok.

%% The second kill of a run with one node alone. `Down' is the node of
%% the first kill. The process approves the kill of `Victim' if the
%% cluster has a later epoch than at the first kill, every LogServer of
%% that epoch runs, no LogServer of it is on the node `Down', and the
%% StorageServers of the two nodes that run are current. The cluster has
%% then recovered from the first kill.
alone_second(Tab, Down, Victim) ->
    [{alone_epoch, Before}] = ets:lookup(Tab, alone_epoch),
    case etx:status() of
        #{
            epoch := Epoch,
            logs := #{total := Logs, up := Logs},
            storages := #{up := 2, current := 2},
            nodes := #{Down := #{logs := 0}}
        } when is_integer(Epoch), Epoch > Before, Logs >= 2 ->
            true = ets:insert(Tab, {alone_approved, 2, Victim});
        _NotRecovered ->
            _ = ets:update_counter(Tab, kills_refused_by_status, 1, {kills_refused_by_status, 0})
    end,
    ok.

%% Creates the table of the run with the 4 accounts and the counter, and
%% records the row `ready'.
setup(Tab) ->
    %% The client waits until etx has started on its node, as a process of
    %% an application waits for the start of etx.
    case ets:member(Tab, {started, node()}) of
        true ->
            setup_table(Tab);
        false ->
            ok = timer:sleep(10),
            setup(Tab)
    end.

setup_table(Tab) ->
    T = etx:open(bank),
    _ = etx:insert_new(T, [{Account, total() div length(accounts())} || Account <- accounts()] ++ [{counter, 0}]),
    true = ets:insert(Tab, {ready, T}),
    ok.

%% Runs the operation `C' of the workload on the node of the caller. `R'
%% selects the kind.
%%
%% <ul>
%% <li>A transfer: one transaction reads two accounts and moves an amount
%%   of 1 to 5 from one to the other. The transaction also inserts an
%%   object with the number of the operation, which shows a second
%%   application of the transfer.</li>
%% <li>A read of the accounts: `tab2list/1' and a `select/2' each read the
%%   4 accounts in one transaction. The sum of each read must be the sum
%%   at the start, for the invariant `conservation'.</li>
%% <li>A count: `update_counter/3' on the counter. The client records the
%%   stamps before and after the call and the result.</li>
%% <li>A read of the counter, with the stamp before the call.</li>
%% <li>A write without a read: `insert/2' of a new object. The read of the
%%   last client of each node must have the object, for the invariant
%%   `durable'.</li>
%% </ul>
%%
%% A call of `etx' waits while the cluster has no epoch, so a client can
%% wait until the end of the run.
op(Tab, C, R) ->
    %% A client waits for the table of the run, and for the start of etx
    %% on its node.
    case {ets:lookup(Tab, ready), ets:member(Tab, {started, node()})} of
        {[{ready, T}], true} ->
            op(Tab, T, C, R);
        _ ->
            ok = timer:sleep(20),
            op(Tab, C, R)
    end.

op(Tab, T, C, R) ->
    Node = node(),
    case R rem 10 of
        Transfer when Transfer < 4 ->
            From = lists:nth((R div 10) rem 4 + 1, accounts()),
            To = lists:nth((R div 40) rem 4 + 1, accounts()),
            Amount = (R div 160) rem 5 + 1,
            true = ets:insert(Tab, {{transfer_started, C}, Node}),
            ok = etx:transaction(T, fun(Tx) ->
                %% The transaction also inserts an object with the number
                %% of the operation. If the object exists, an earlier run
                %% of this function is committed, and this run applies the
                %% transfer a second time. The client records that for
                %% the invariant `at_most_once'.
                _ = etx:insert_new(Tx, {{applied, C}, Node}) orelse ets:insert(Tab, {{applied_twice, C}, Node}),
                [{From, A}] = etx:lookup(Tx, From),
                [{To, B}] = etx:lookup(Tx, To),
                case From =:= To of
                    true ->
                        ok;
                    false ->
                        true = etx:insert(Tx, [{From, A - Amount}, {To, B + Amount}]),
                        ok
                end
            end),
            true = ets:insert(Tab, {{transfer, C}, Node});
        Read when Read < 6 ->
            Rows = [Row || Row = {{acct, _}, _} <- etx:tab2list(T)],
            Selected = etx:select(T, [{{{acct, '$1'}, '$2'}, [], [{{{{acct, '$1'}}, '$2'}}]}]),
            Sums = {lists:sum([V || {_, V} <- Rows]), lists:sum([V || {_, V} <- Selected])},
            Expected = {total(), total()},
            true = ets:insert(Tab, {{read, C}, Node}),
            _ = Sums =:= Expected orelse ets:insert(Tab, {{sum_differs, C}, #{node => Node, rows => Rows, selected => Selected}}),
            ok;
        Count when Count < 9 ->
            Start = ets:update_counter(Tab, stamp, 1, {stamp, 0}),
            true = ets:insert(Tab, {{count_started, C}, Node}),
            Value = etx:update_counter(T, counter, 1),
            End = ets:update_counter(Tab, stamp, 1, {stamp, 0}),
            true = ets:insert(Tab, {{count, C}, #{node => Node, start => Start, 'end' => End, value => Value}});
        _ when (R div 10) rem 2 =:= 0 ->
            Start = ets:update_counter(Tab, stamp, 1, {stamp, 0}),
            Value = etx:lookup_element(T, counter, 2),
            true = ets:insert(Tab, {{count_read, C}, #{node => Node, start => Start, value => Value}});
        _ ->
            %% A write without a read: a new object with the number of the
            %% operation. The client records the stamp after the call.
            true = etx:insert(T, {{note, C}, Node}),
            End = ets:update_counter(Tab, stamp, 1, {stamp, 0}),
            true = ets:insert(Tab, {{note, C}, End})
    end.

%% The last operation of a node: a count, a write without a read, and a
%% read of every object. The
%% harness compares the reads of the nodes in `check_final/2'.
final(Tab, T) ->
    Node = node(),
    Start = ets:update_counter(Tab, stamp, 1, {stamp, 0}),
    true = ets:insert(Tab, {{count_started, {final, Node}}, Node}),
    Value = etx:update_counter(T, counter, 1),
    End = ets:update_counter(Tab, stamp, 1, {stamp, 0}),
    true = ets:insert(Tab, {{count, {final, Node}}, #{node => Node, start => Start, 'end' => End, value => Value}}),
    %% A write without a read, so that the last client also checks that
    %% such a write ends.
    true = etx:insert(T, {{final_note, Node}, Value}),
    ReadStart = ets:update_counter(Tab, stamp, 1, {stamp, 0}),
    Rows = etx:tab2list(T),
    %% A read on a node whose StorageServer is behind goes to the
    %% StorageServer of another node, so the read above does not show
    %% that the StorageServer of this node has the data. The last client
    %% therefore also waits until `etx:status/0' reports the
    %% StorageServer of this node as current.
    ok = await_current(Node),
    true = ets:insert(Tab, {{final, Node}, Rows, ReadStart}).

await_current(Node) ->
    case etx:status() of
        #{nodes := #{Node := #{storage := #{current := true}}}} ->
            ok;
        _NotCurrent ->
            ok = timer:sleep(100),
            await_current(Node)
    end.
