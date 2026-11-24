%% The simulation suite of etx. See `etx_dst' for the harness.
-module(etx_dst_tests).

-include_lib("eunit/include/eunit.hrl").

-export([opts/2, calm/1, run/1]).

%% The limit for one test, in seconds.
-define(TIMEOUT, 900).

opts(Seed, Config) ->
    #{
        seed => Seed,
        config => Config#{last_op => 60},
        max_ops => 60,
        max_steps => 600000,
        %% After the last operation, a call that was in progress can wait
        %% for its time limit, and the cluster can need a new epoch.
        settle_steps => 60000,
        %% The probability that a step injects an operation. The servers
        %% of peace send heartbeats, so a run has many steps for each unit
        %% of the virtual clock.
        op_p => 0.004,
        quiet_p => 0.8,
        preload => [etx, redwall, peace],
        disk => true,
        %% The network delays messages and does not lose a message. etx
        %% runs on Erlang distribution, which does not lose a message of a
        %% connection that stays up. A partition of the harness ends a
        %% connection, and each side receives `noconnection'.
        net => #{policy => #{drop_p => 0.0, delay_p => 0.2, max_delay => 5}}
    }.

%% The options for a run without kills, partitions and lost messages.
calm(Seed) ->
    (opts(Seed, #{faults => false}))#{net => true}.

run(Opts) ->
    ok = instrument(supervisor),
    eta_run:run(etx_dst, Opts).

%% Rewrites the module `supervisor' of Erlang/OTP in memory with the parse
%% transform of eta, once in a node. etx starts its processes through
%% supervisors. Without the rewrite, the module starts a child outside the
%% gate of the scheduler: the child runs before the scheduler has adopted
%% it and before it has the simulated node of its parent, so a run is not
%% a function of its seed.
%%
%% The function follows `Eta.Beam.instrument/1' of eta, which is a module
%% for Elixir.
instrument(Module) ->
    case persistent_term:get({?MODULE, instrumented, Module}, false) of
        true ->
            ok;
        false ->
            {Module, Beam, File} = code:get_object_code(Module),
            {ok, {Module, [{debug_info, {debug_info_v1, Backend, Data}}]}} = beam_lib:chunks(Beam, [debug_info]),
            {ok, Forms} = Backend:debug_info(erlang_v1, Module, Data, []),
            {ok, Module, Rewritten, _Warnings} = compile:forms(eta_transform:parse_transform(Forms, []), [debug_info, return_errors, return_warnings]),
            %% The directory of stdlib is sticky, which refuses a load.
            _ = code:unstick_mod(Module),
            _ = code:purge(Module),
            {module, Module} = code:load_binary(Module, File, Rewritten),
            ok = eta_sched:instrumented([Module]),
            persistent_term:put({?MODULE, instrumented, Module}, true)
    end.

%% The same seed gives the same trace, the audit of eta reports nothing,
%% and the trace replays.
determinism_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        lists:foreach(
            fun(Seed) ->
                Opts = opts(Seed, #{}),
                [First | _] = Results = [run(Opts) || _ <- lists:seq(1, 3)],
                ?assertEqual(1, length(lists:usort([maps:get(trace, R) || R <- Results])), {seed, Seed, [eta_run:summary(R) || R <- Results]}),
                ?assertEqual(ok, eta_run:audit(First), {seed, Seed, eta_run:summary(First)}),
                Replayed = eta_run:replay(etx_dst, maps:get(trace, First), Opts),
                ?assertEqual({maps:get(outcome, First), 0}, {maps:get(outcome, Replayed), maps:get(skipped, Replayed)}, {seed, Seed})
            end,
            lists:seq(1, 8)
        )
    end}.

%% Runs without faults. 50 seeds.
calm_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = etx_dst:reset_stats(),
        sweep(lists:seq(1, 50), fun calm/1),
        Stats = etx_dst:stats(),
        ?debugFmt("calm: ~p", [Stats]),
        ok = write_stats({calm, 1}, Stats),
        %% The operations of a run without faults end. A run ends when the
        %% last client of each node has ended, and a client that started
        %% at the same time can then be in progress.
        ?assert(maps:get(transfers, Stats) * 100 >= maps:get(transfers_started, Stats) * 98, Stats),
        ?assert(maps:get(counts, Stats) * 100 >= maps:get(counts_started, Stats) * 98, Stats),
        ?assert(maps:get(transfers, Stats, 0) > 800, Stats)
    end}.

%% Runs with kills and restarts of one node, and with partitions. 300
%% seeds in 3 shards.
faults_1_test_() -> faults_shard(1).
faults_2_test_() -> faults_shard(2).
faults_3_test_() -> faults_shard(3).

faults_shard(Shard) ->
    {timeout, ?TIMEOUT, fun() ->
        ok = etx_dst:reset_stats(),
        sweep(lists:seq((Shard - 1) * 100 + 1, Shard * 100), fun(Seed) -> opts(Seed, #{}) end),
        Stats = etx_dst:stats(),
        ?debugFmt("faults ~p: ~p", [Shard, Stats]),
        ok = write_stats({faults, Shard}, Stats),
        ?assert(maps:get(transfers, Stats, 0) > 1000, Stats),
        ?assert(maps:get(counts, Stats, 0) > 800, Stats),
        ?assert(maps:get(kills, Stats, 0) > 50, Stats),
        ?assert(maps:get(restarts, Stats, 0) > 30, Stats),
        ?assert(maps:get(partitions, Stats, 0) > 60, Stats)
    end}.

%% A planted defect: a transfer writes the two accounts in two
%% transactions.
split_transfer_is_found_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Seed, Violation} = first_violation(lists:seq(1, 100), fun(Seed) -> opts(Seed, #{mode => split_transfer}) end),
        ?debugFmt("split_transfer: seed ~p, ~p", [Seed, Violation]),
        ?assertMatch(#{property := conservation}, Violation)
    end}.

%% A planted defect: a count reads the counter in one transaction and
%% writes it in another.
lost_update_is_found_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Seed, Violation} = first_violation(lists:seq(1, 100), fun(Seed) -> opts(Seed, #{mode => lost_update}) end),
        ?debugFmt("lost_update: seed ~p, ~p", [Seed, Violation]),
        ?assert(lists:member(maps:get(property, Violation), [counter_unique, counter_order, stale_read]), Violation)
    end}.

%% A planted defect: the cluster has no idempotency ids. A call of
%% `update_counter/3' is applied two times after a commit without an
%% answer. The same seed passes with idempotency ids.
no_idempotency_is_found_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Seed, Violation} = first_violation(lists:seq(1, 300), fun(Seed) -> opts(Seed, #{mode => no_idempotency}) end),
        ?debugFmt("no_idempotency: seed ~p, ~p", [Seed, Violation]),
        ?assertMatch(#{property := at_most_once}, Violation),
        ?assertEqual(ok, maps:get(outcome, run(opts(Seed, #{}))), {seed, Seed})
    end}.

%% The options of a run with kills and restarts of different nodes, one at
%% a time. The run has 200 operations, because the harness kills the next
%% node only after the cluster has recovered.
rolling(Seed, Config) ->
    Opts = #{config := Config1} = opts(Seed, Config#{rolling => true}),
    Opts#{config := Config1#{last_op => 200}, max_ops => 200, max_steps => 2000000}.

%% Runs with kills and restarts of different nodes, one at a time. 100
%% seeds.
rolling_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = etx_dst:reset_stats(),
        sweep(lists:seq(1, 100), fun(Seed) -> rolling(Seed, #{}) end),
        Stats = etx_dst:stats(),
        ?debugFmt("rolling: ~p", [Stats]),
        ok = write_stats({rolling, 1}, Stats),
        ?assert(maps:get(kills, Stats, 0) > 150, Stats),
        ?assert(maps:get(restarts, Stats, 0) > 150, Stats),
        ?assert(maps:get(runs_with_kills_of_several_nodes, Stats, 0) > 50, Stats),
        ?assert(maps:get(transfers, Stats, 0) > 2000, Stats)
    end}.

%% A planted defect: a StorageServer that starts again does not copy the
%% data from another StorageServer. After kills of two different nodes, a
%% record of an earlier epoch is on no LogServer, and a run ends with a
%% node that does not answer. The same seed passes with the copy.
no_copy_is_found_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Seed, Violation} = first_violation(lists:seq(1, 100), fun(Seed) -> rolling(Seed, #{mode => no_copy}) end),
        ?debugFmt("no_copy: seed ~p, ~p", [Seed, Violation]),
        ?assertMatch(#{property := final}, Violation),
        ?assertEqual(ok, maps:get(outcome, run(rolling(Seed, #{}))), {seed, Seed})
    end}.

%% A planted defect: the nodes are restarted one after another without a
%% question to `etx:status/0'. A second node stops before the cluster has
%% recovered from the stop of the first, and the cluster loses its
%% tables. The same seed passes when `etx:status/0' approves
%% each stop.
no_status_is_found_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Seed, Violation} = first_violation(lists:seq(1, 200), fun(Seed) -> rolling(Seed, #{mode => no_status}) end),
        ?debugFmt("no_status: seed ~p, ~p", [Seed, Violation]),
        %% The cluster loses 2 LogServers of one epoch and resets the
        %% database. A read then does not find the accounts, or a node
        %% does not answer.
        ?assert(lists:member(maps:get(property, Violation), [conservation, durable, final]), Violation),
        ?assertEqual(ok, maps:get(outcome, run(rolling(Seed, #{}))), {seed, Seed})
    end}.

%% Runs with a stop and a start of every node at the operation 30, and
%% with the kills, restarts and partitions of the other runs before and
%% after it. 100 seeds.
full_restart_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        ok = etx_dst:reset_stats(),
        sweep(lists:seq(1, 100), fun(Seed) -> opts(Seed, #{restart_at => 30}) end),
        Stats = etx_dst:stats(),
        ?debugFmt("full restart: ~p", [Stats]),
        ok = write_stats({full_restart, 1}, Stats),
        ?assertEqual(100, maps:get(restarts_of_every_node, Stats, 0), Stats),
        ?assert(maps:get(transfers, Stats, 0) > 600, Stats),
        ?assert(maps:get(kills, Stats, 0) > 50, Stats)
    end}.

%% A planted defect: the cluster does not reset the database after the
%% loss of the LogServers of an epoch. After the restart of every node,
%% the cluster has no epoch, and a run ends with nodes that do not answer.
%% The same seed passes with the reset.
no_reset_is_found_test_() ->
    {timeout, ?TIMEOUT, fun() ->
        {Seed, Violation} = first_violation(lists:seq(1, 20), fun(Seed) -> opts(Seed, #{restart_at => 30, mode => no_reset}) end),
        ?debugFmt("no_reset: seed ~p, ~p", [Seed, Violation]),
        ?assertMatch(#{property := final}, Violation),
        ?assertEqual(ok, maps:get(outcome, run(opts(Seed, #{restart_at => 30}))), {seed, Seed})
    end}.

sweep(Seeds, OptsFun) ->
    lists:foreach(
        fun(Seed) ->
            Result = run(OptsFun(Seed)),
            ?assertEqual(ok, maps:get(outcome, Result), {seed, Seed, eta_run:summary(Result)}),
            ?assertEqual(ok, eta_run:audit(Result), {seed, Seed, eta_run:summary(Result)})
        end,
        Seeds
    ).

first_violation([], _OptsFun) ->
    error(no_seed_found_the_defect);
first_violation([Seed | Seeds], OptsFun) ->
    case run(OptsFun(Seed)) of
        #{outcome := {violation, Violation}} -> {Seed, Violation};
        #{outcome := ok} -> first_violation(Seeds, OptsFun);
        Result -> error({seed, Seed, eta_run:summary(Result)})
    end.

%% Writes the statistics of a test to the directory that the environment
%% variable ETX_DST_STATS_DIR names. `dst/run.sh' sets the variable and
%% prints the sums.
write_stats({Kind, Shard}, Stats) ->
    case os:getenv("ETX_DST_STATS_DIR") of
        false ->
            ok;
        Dir ->
            File = filename:join(Dir, lists:concat([Kind, "_", Shard, ".stats"])),
            file:write_file(File, io_lib:format("~p.~n", [{Kind, Stats}]))
    end.
