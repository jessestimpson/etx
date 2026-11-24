# etx

[![CI](https://github.com/jessestimpson/etx/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/jessestimpson/etx/actions/workflows/ci.yml)

etx (Erlang Term Transactions) is an Erlang application that gives
[redwall](https://github.com/jessestimpson/redwall) the interface of `ets`. A table of etx has the
functions of an ETS table of the type `ordered_set`. The table is in a
cluster of redwall, so every node of the cluster has the same table, and
each function is a transaction with strict serializability.

## Example

`sys.config` for a cluster of one node:

```erlang
[{etx, [{clusters, #{default => #{}}}]}].
```

```erlang
{ok, _} = application:ensure_all_started(etx),
T = etx:open(accounts),
true = etx:insert(T, [{alice, 10}, {bob, 5}]),
[{alice, 10}] = etx:lookup(T, alice),
11 = etx:update_counter(T, alice, 1),
[bob] = etx:select(T, [{{'$1', '$2'}, [{'<', '$2', 10}], ['$1']}]),

%% Several functions in one transaction.
ok = etx:transaction(T, fun(Tx) ->
    [{alice, A}] = etx:lookup(Tx, alice),
    [{bob, B}] = etx:lookup(Tx, bob),
    true = etx:insert(Tx, [{alice, A - 3}, {bob, B + 3}]),
    ok
end).
```

### Example with three nodes

This example runs in `rebar3 shell --sname etx`. The node of the shell is
the first node. The example starts two more Erlang nodes on the same
computer with the module `peer` of Erlang/OTP, and the three nodes run
etx with the same cluster. The node of the shell needs a name, because
the three nodes use Erlang distribution.

```erlang
%% Two more nodes on this computer. The shell controls each of them
%% through its standard input and output.
Args = ["-setcookie", atom_to_list(erlang:get_cookie()), "-pa" | [P || P <- code:get_path(), filelib:is_dir(P)]],
Start = fun() ->
    {ok, Peer, Node} = peer:start(#{name => peer:random_name(), connection => standard_io, args => Args}),
    {Peer, Node}
end,
[{P2, N2}, {P3, N3}] = [Start(), Start()],

%% The same configuration on each node: one cluster with three
%% coordinators. The node of the shell is the first of the three nodes.
Cluster = #{coordinators => [{etx_c, Node} || Node <- [node(), N2, N3]], fresh => true},
[begin
     ok = peer:call(Peer, application, set_env, [etx, clusters, #{default => Cluster}]),
     {ok, _} = peer:call(Peer, application, ensure_all_started, [etx])
 end || Peer <- [P2, P3]],
%% `rebar3 shell' has started etx on this node without a cluster.
_ = application:stop(etx),
ok = application:set_env(etx, clusters, #{default => Cluster}),
{ok, _} = application:ensure_all_started(etx),

%% A table that this node opens is a table of every node.
T = etx:open(accounts),
true = etx:insert(T, {alice, 10}),
[{alice, 10}] = peer:call(P2, etx, lookup, [T, alice]),
11 = peer:call(P3, etx, update_counter, [T, alice, 1]),
[{alice, 11}] = etx:lookup(T, alice),

%% An update on this node takes about 150 us. The update is one
%% transaction, and it is consistent across the cluster in that time: when
%% the call returns, a read on any node returns the new value.
12 = etx:update_counter(T, alice, 1),
[{alice, 12}] = peer:call(P2, etx, lookup, [T, alice]),
[{alice, 12}] = peer:call(P3, etx, lookup, [T, alice]),

%% The third node stops. This node and the second node continue with the
%% table.
ok = peer:stop(P3),
13 = etx:update_counter(T, alice, 1),
[{alice, 13}] = peer:call(P2, etx, tab2list, [T]),

ok = peer:stop(P2).
```

- A call of `etx` in the shell runs on the first node, and a call of
  `peer:call/4` runs a function of `etx` on the second node or on the
  third node.
- `T` is a term. The handle that the first node returns is a handle on
  the second node and on the third node.
- The time of about 150 us is from 3 runs of 10,000 calls of
  `update_counter/3` on the node of the shell on 2026-11-23, with the
  three nodes on one computer and with idempotency ids: the p50 is 135 us
  to 139 us, the p99 is 184 us to 201 us, and the first call takes 183 us
  to 193 us.
- After the stop of the third node, the cluster has 2 of 3 coordinators.
  Each LogServer of an epoch is on a node of its own, so each record of
  the log is on a node that still runs. The ClusterController starts a
  new epoch, and `update_counter/3` waits for it. That call takes 521
  ms to 571 ms in 6 runs.
- The whole example takes 868 ms to 909 ms in 3 runs on 2026-11-23, with
  the start and the stop of the two nodes.
- `fresh => true` deletes the data of the coordinator of each node before
  the start. See "Limitations".

## Features

- `etx:open/1,2` takes the place of `ets:new/2`. It creates the table if
  the cluster does not have it, and returns a handle. The other functions
  have the names, the arguments and the results of `ets`.
- A function with a handle of `open/2` is one transaction. For example,
  `update_counter/3` reads and writes in one transaction, so two callers
  on two nodes do not lose an update.
- `etx:transaction/2` runs a function with a handle that is bound to one
  transaction. Every function with that handle is a part of the
  transaction. With a list of handles of one cluster, the function
  receives a list of bound handles, so a transaction can change several
  tables.
- A key and an object are Erlang terms. etx does not encode them. The
  key of an object in redwall is the list `[etx, Name, Key]`, and the
  objects of a table are the keys with the prefix `[etx, Name]`, which
  are one key range.
- A match spec is evaluated in the StorageServer of redwall
  (`redwall:select/5`), so an object that does not match does not leave
  the StorageServer.
- Each node of a cluster has every object in ETS tables in memory. A read
  does not leave the node.
- The application starts one cluster or several clusters from its
  configuration.

## Functions

| Group | Functions of `etx` |
|---|---|
| Tables | `open/1,2`, `delete/1`, `info/1,2`, `clusters/0` |
| Clusters | `status/0,1` |
| Transactions | `transaction/2` |
| Objects | `insert/2`, `insert_new/2`, `lookup/2`, `lookup_element/3,4`, `member/2`, `take/2`, `delete/2`, `delete_object/2`, `delete_all_objects/1` |
| Order of the keys | `first/1`, `next/2`, `last/1`, `prev/2` |
| Match specs and patterns | `select/1,2,3`, `select_count/2`, `select_delete/2`, `match/2`, `match_object/2`, `match_delete/2` |
| Whole table | `tab2list/1`, `foldl/3`, `foldr/3` |
| Updates | `update_counter/3,4`, `update_element/3` |

Options of `open/2`:

| Option | Meaning | Default |
|---|---|---|
| `{cluster, Name}` | The cluster of the table | `default`, or the only cluster of the node |
| `{keypos, Pos}` | The element of an object that is the key | 1 |
| `set`, `ordered_set` | The type. Both give a table with ordered keys | `ordered_set` |

## Status

`etx:status/0,1` returns the health of a cluster and its fault tolerance
in Erlang nodes. The result is the result of `redwall_status:status/1`.
The nodes of a cluster are the nodes with a coordinator.

```erlang
1> etx:status().
#{healthy => true,
  epoch => 1,
  generation => 0,
  fault_tolerance =>
      #{max_node_failures_without_losing_availability => 1,
        max_node_failures_without_losing_data => 1,
        safe_to_stop => ['a@host1','b@host2','c@host3']},
  coordinators => #{total => 3,up => 3,majority => 2},
  logs => #{total => 2,up => 2,replication => 2},
  storages => #{total => 3,up => 3,current => 3},
  workers => #{min => 2,registered => 3},
  controller => 'b@host2',
  nodes => #{'a@host1' => #{coordinator => up,worker => true,logs => 1,
                            storage => #{version => 12112,current => true,copying => false}},
             ...},
  problems => []}
```

- `healthy` is `true` if the cluster has an epoch, and every
  coordinator, every LogServer of the epoch and every StorageServer runs
  and is current.
- `max_node_failures_without_losing_data` and
  `max_node_failures_without_losing_availability` are the numbers of
  nodes that can stop at the same time.
- `safe_to_stop` has the nodes whose stop alone leaves the cluster
  available.
- `problems` has the reasons for which the cluster is not healthy, for
  example `{coordinator_down, Node}` and `{storage_copying, Node}`.
- With three nodes on one computer, a call takes about 5 ms. A call to a
  node that does not answer takes up to 1 second.

To restart the nodes of a cluster one after another:

1. Call `etx:status/0`. Continue only if `healthy` is `true` and the
   node is in `safe_to_stop`.
2. Stop the node, and start it again.
3. Repeat from step 1 for the next node. `healthy` is `true` again when
   the cluster has a new epoch and the StorageServer of the node has
   copied the data.

## Configuration

The key `clusters` of the application environment is a map from the name
of a cluster to its options. The application starts the processes of each
cluster on the node ([src/etx_cluster.erl](src/etx_cluster.erl)).

| Option of a cluster | Meaning | Default |
|---|---|---|
| `coordinators` | The servers of the peace cluster with the coordinated state: a list of `{Name, Node}`. Every node of the cluster has the same list | One coordinator on this node, which gives a cluster of one node |
| `dir` | The directory of the coordinator of this node | A directory with the names of the cluster and of the node, below the cache directory of the user for `etx` |
| `fresh` | Delete the data of the coordinator of this node before the start, for a cluster that starts as a new cluster | `false` |
| `reset_after_log_loss` | Start the cluster again without its tables after the loss of the LogServers of an epoch, for example after the stop of every node. redwall writes a warning to the log at a reset, and `etx:status/0` has the number of resets in the key `generation` | The default of redwall: `true` for LogServers in memory |
| `logs` | The number of LogServers of an epoch. In a cluster of several nodes, each LogServer is on a node of its own, so an epoch has at most one LogServer for each node that runs | 3 |
| `replication` | The number of LogServers with each record. It is at most the number of LogServers of the epoch | 2 |
| `automatic_idempotency` | Give each transaction an idempotency id of redwall, so that a transaction whose commit has no answer is not applied a second time | `true` |
| `storage_copy` | A StorageServer that starts without data copies the data from the StorageServer of another node with a coordinator | `true` |
| `storage` | Start a StorageServer on this node. Without one, the functions of `etx` on this node read from the StorageServers of the other nodes by message | `true` |

A cluster of three nodes, with the same configuration on each node:

```erlang
[{etx, [{clusters, #{
    default => #{
        coordinators => [{etx_c, 'a@host1'}, {etx_c, 'b@host2'}, {etx_c, 'c@host3'}],
        dir => "/var/lib/etx"
    }
}}]}].
```

Each node starts these processes for a cluster:

1. The coordinator of the node, if `coordinators` names the node.
2. A process that forms the peace cluster of the coordinators. It tries
   again every 100 ms until every coordinator runs, and then ends.
3. The worker of the node, with a candidate for the ClusterController.
   The ClusterController starts the LogServers and the process of each
   epoch on the workers.
4. The StorageServer of the node.

A cluster of several nodes starts its first epoch when the workers of 2
nodes run. A function of `etx` that runs before the cluster has its
first epoch waits for the epoch.

## Verification

`make test` runs 13 tests. Results on 2026-11-24, with Erlang/OTP 28:

| Test | Result |
|---|---|
| The functions for objects, for the order of the keys, for `keypos`, and the errors | Pass |
| `update_counter` and `update_element`: 20 calls give the results and the table of `ets` | Pass |
| Keys that are equal and not identical, such as 1 and 1.0, and keys of every type: 70 calls give the results of `ets`, compared with `=:=` | Pass |
| 11 match specs and 6 patterns give the results of `ets`, also with a limit of 4 and continuations, and with `select_delete` and `match_delete` | Pass |
| 600 random functions on a table of etx and on an ETS table of the type `ordered_set` give the same results. 17 keys, of which 3 pairs are equal and not identical | Pass |
| `transaction/2` with one table and with two tables, a function that fails, and a transaction in a transaction | Pass |
| 8 processes change one object 50 times each, and 4 processes move amounts between two objects 50 times each. No change is lost, and each read of the two objects has the same sum | Pass |
| Two clusters on one node have two tables with one name | Pass |
| The application stops and starts again | Pass |
| Three nodes with three coordinators: a table of one node is a table of every node, 90 changes of one object from three nodes, and the stop of one node | Pass |
| Every node of a cluster of three nodes stops and starts again with the directories of its coordinators: the cluster starts without its tables, and is healthy with a later epoch | Pass |

### Simulation

`make dst` runs etx under the scheduler, the simulated network and the
simulated disk of [eta](../eta). The harness is
[dst/etx_dst.erl](dst/etx_dst.erl).

- Three simulated nodes each run the supervisor of etx, which starts the
  processes of one cluster from the application environment: a
  coordinator on the simulated disk, the process that forms the peace
  cluster, a worker with a candidate for the ClusterController, and a
  StorageServer.
- etx, redwall and peace are compiled with the parse transform of eta.
  The suite also rewrites the module `supervisor` of Erlang/OTP in memory
  with that transform, because etx starts its processes through
  supervisors.
- Clients on the three nodes run transfers between 4 accounts in
  `transaction/2`, reads of the accounts, `update_counter/3` and reads
  of the counter.
- The harness kills one node and starts it again, any number of times,
  and cuts connections between nodes. After 60 operations it removes the
  faults and starts a last client on each node.

| Invariant | Meaning |
|---|---|
| `conservation` | Each read of the 4 accounts in one transaction has the sum of the accounts at the start |
| `counter_unique` | No two calls of `update_counter/3` return the same value |
| `counter_order` | A call of `update_counter/3` that starts after the end of another call, on any node, returns a higher value |
| `stale_read` | A read of the counter returns at least the value of every call of `update_counter/3` that ended before the read started |
| `final` | At the end of a run, the last client of each node has ended: a count and a read of every object |
| `at_most_once` | No transaction is applied a second time after its commit. A transfer inserts an object with the number of its operation, and finds the object in a second application |
| `durable` | The read of the last client of each node has every object of a write without a read that ended before the read started |

Results of `make dst` on 2026-11-24. The 13 tests pass in 64 s:

| Test | Runs | Result |
|---|---|---|
| The same seed gives the same trace, the trace replays, and the audit of eta reports nothing | 8 seeds, 3 runs each | Pass |
| No faults | 50 seeds, 60 operations each | No violation. 1,169 transfers, 1,001 counts, 579 reads of the accounts, 147 writes without a read |
| Kills and restarts of one node, and partitions | 300 seeds in 3 tests | No violation. 4,905 transfers, 4,019 counts, 2,621 reads of the accounts, 677 writes without a read, 516 kills of a node, also during the start of the cluster, 362 restarts, 313 partitions |
| Kills and restarts of different nodes, one at a time. A process of another node asks `etx:status/0`, and the node is killed only if the cluster is healthy and the node is in `safe_to_stop` | 100 seeds, 200 operations each | No violation. 3,730 transfers, 2,751 counts, 212 kills that the status approved, 2,681 kills that it refused, 207 restarts, 82 runs with kills of two or three different nodes |
| A stop and a start of every node at the operation 30, with the kills, restarts and partitions of the other runs before and after it | 100 seeds | No violation. 100 restarts of every node, after each of which the cluster starts without its tables and a client creates the table again. 916 transfers, 218 kills of a node, 93 partitions |
| Planted defect: a transfer in two transactions | Seeds from 1 | Found at seed 1, `conservation` |
| Planted defect: a count with a read and a write in two transactions | Seeds from 1 | Found at seed 1, `counter_unique` |
| Planted defect: a cluster without idempotency ids (`automatic_idempotency => false`) | Seeds from 1 | Found at seed 6, `at_most_once`: a transfer is applied a second time. The same seed passes with idempotency ids |
| Planted defect: a cluster without the copy of a StorageServer (`storage_copy => false`) | Seeds from 1, runs with kills of different nodes | Found at seed 2, `final`: a node does not answer. The same seed passes with the copy |
| Planted defect: the nodes are restarted one after another without a question to `etx:status/0` | Seeds from 1, runs with kills of different nodes | Found at seed 1, `conservation`: the cluster loses 2 LogServers of one epoch and starts again without its tables, and a read does not find the accounts. The same seed passes when the status approves each stop |
| Planted defect: a cluster without the reset (`reset_after_log_loss => false`) | Seeds from 1, runs with a restart of every node | Found at seed 1, `final`: the cluster has no epoch, and no node answers. The same seed passes with the reset |

The simulation found these problems on 2026-11-23:

| Problem | Status |
|---|---|
| A transaction is applied two times. The process of the epoch stops after the commit is durable and before the client has the answer. The client receives the error 1021, and `redwall:transactional/2` runs the transaction again | Fixed on 2026-11-23 with the idempotency ids of redwall, which etx uses for every transaction |
| A write without a read never ends after a recovery, when the transaction has an idempotency id. The transaction has a read conflict key and no read version, so the Resolver answers that it is too old. The three-node unit test found it | Fixed in redwall: such a transaction asks for a read version at its commit. The last client of a run now also writes without a read; without the fix, 16 seeds of 30 fail |
| A StorageServer waits for an ended epoch without an end, when no LogServer of that epoch can answer that it is stopped. 1 seed of 300 | Fixed in redwall: the StorageServer reads the coordinated state at every tenth interval and after a failed request |
| A read returns a part of the objects, or none. The read waits while the StorageServer of a restarted node copies, and has a read version below the version of the copy. The invariant `conservation` found it in 29 seeds of 100 during the work on the copy | Fixed in redwall before the copy was committed: such a read is answered with too old, and the client reads again |
| No StorageServer has the data after restarts of two nodes. A StorageServer that is cut off stays without data, answers that it is empty, and the restarted StorageServers then read a log that does not exist | Fixed in redwall: a StorageServer that makes no progress in an ended epoch copies from a peer that is ahead. The rolling runs also wait until every StorageServer has the data |
| With random loss of single messages, every commit of a cluster stops while every process runs, in 18 seeds of 40. redwall does not send a message to a LogServer again | Not fixed in redwall. The runs of etx lose no single message, because Erlang distribution does not lose a message of a connection that stays up. A partition ends a connection |
| After kills of two different nodes, one at a time and with a restart in between, a node does not answer, in 4 seeds of 60. A LogServer keeps its records in memory, so a record of an earlier epoch can then be on no LogServer, and a StorageServer that starts cannot read it | Fixed on 2026-11-24 for restarts that wait for a recovered cluster: a StorageServer that starts without data copies the data from the StorageServer of another node. A second kill before the cluster has recovered from the first still ends the cluster. See "Limitations" |

Limitations of the simulation:

- A run does not stop every node. The runs with kills of different
  nodes have no partition, and kill a node only after `etx:status/0` has
  approved the stop.
- A run has one cluster and one table.
- A client calls `open/1`, `insert_new/2`, `lookup/2`, `insert/2`,
  `tab2list/1`, `select/2`, `update_counter/3`, `lookup_element/3` and
  `transaction/2`. The unit tests compare the other functions with
  `ets`.
- The application controller is not in a run. A process of the harness
  starts the supervisor of etx on each node.
- The network loses no single message.

## Limitations

- With the cluster option `automatic_idempotency => false`, a function
  that writes can be applied two times, when the process of an epoch
  stops after a commit is durable and before the client has the answer.
  The default is `true`.
- The nodes of a cluster can be restarted one after another without the
  loss of the tables only with a wait between two restarts.
  `etx:status/0` reports when the next node can stop. See "Status".
- `etx:status/0` reports the stop of nodes. It does not examine
  partitions, and its result is not the state of one moment.

- The data of a table is in memory. A LogServer and a StorageServer of
  redwall have no disk. The data does not survive the stop of every node
  of the cluster.
- After the stop of every node of a cluster, the cluster starts again
  without its tables. The coordinators keep the coordinated state on
  disk, so the nodes form the same cluster, and the recovery resets the
  database, because no LogServer of the last epoch runs.
- The same reset happens when 2 LogServers of one epoch are lost while
  other nodes run, for example when a second node stops before the
  cluster has recovered from the stop of the first. The cluster then
  continues without its tables. `etx:status/0` reports when a node can
  stop without this loss.
- A transaction must end within 5 seconds, the MVCC window of redwall.
- A transaction that has a conflict runs again. The function of
  `transaction/2` must give the same result when it runs several times.
- A function waits without a limit of time while the cluster has no
  epoch. A cluster that cannot start an epoch, for example after the
  loss of every LogServer of the last epoch, makes a function wait
  without an end.
- In a cluster of one node, every LogServer is on that node.
- The types `bag` and `duplicate_bag` are not supported.
- `last/1` and `prev/2` read every key of the table below the result,
  because redwall has no read in the reverse order.
- `info/2` with `size` counts the objects in the StorageServer.
- A `select/3` with a limit and its `select/1` are several transactions
  if the handle is not bound to a transaction.
- A table has no owner process and no access rights. The options of ets
  for access, heir, concurrency and compression are ignored.
- These functions of ets are missing: `rename/2`, `give_away/3`,
  `setopts/2`, `safe_fixtable/2`, `slot/2`, `fun2ms/1`, `file2tab`,
  `tab2file`, `select_reverse`, `select_replace`, `first_lookup`,
  `next_lookup`, `whereis/1` and the functions for `dets`.
- A node cannot join a cluster with other coordinators than the
  coordinators of its configuration, and the coordinators of a cluster
  cannot change.
- etx has no benchmark. redwall has one for the transactions that etx
  uses.

## Continuous integration

GitHub Actions runs the workflow [CI](.github/workflows/ci.yml) on each
push to `main` and on each pull request, with Erlang/OTP 28.3 on
`ubuntu-latest`.

| Job | Command |
|---|---|
| Unit tests | `make compile`, `make test` |
| Deterministic simulation | `dst/run.sh -j N`, with N the number of processors of the runner |

- The workflow builds with redwall, peace and eta from the branch `main`
  of their repositories.

## Commands

| Command | Meaning |
|---|---|
| `make compile` | Compile |
| `make test` | Run the tests. The test with three nodes needs `epmd` |
| `make dst` | Run the simulation suite. Each test runs in an Erlang node of its own |

## Requirements

- Erlang/OTP 28
- rebar3
- redwall, from `https://github.com/jessestimpson/redwall.git`, branch
  `main`
- peace, from `https://github.com/jessestimpson/peace.git`, branch `main`
- eta, from `https://github.com/jessestimpson/eta.git`, branch `main`,
  for `make dst`

rebar3 fetches the three applications. For local development, a link at
`_checkouts/redwall`, `_checkouts/peace` or `_checkouts/eta` replaces the
fetched application with a local checkout.

## Source layout

| Path | Contents |
|---|---|
| [src/etx.erl](src/etx.erl) | The functions for tables, with the names of `ets` |
| [src/etx_cluster.erl](src/etx_cluster.erl) | The supervisor of the processes of one cluster on a node |
| [src/etx_sup.erl](src/etx_sup.erl), [src/etx_app.erl](src/etx_app.erl) | The application and its supervisor, which has one child for each cluster |
| [include/etx_eta.hrl](include/etx_eta.hrl) | The header that puts a module under the parse transform of eta in the `dst` profile |
| [dst/etx_dst.erl](dst/etx_dst.erl) | The eta harness: the nodes, the workload, the faults and the invariants |
| [dst/etx_dst_client.erl](dst/etx_dst_client.erl) | The processes of a simulated node: the supervisor of etx and the clients |
| [dst/etx_dst_tests.erl](dst/etx_dst_tests.erl), [dst/run.sh](dst/run.sh) | The simulation suite and the script that runs it |
| [test/etx_tests.erl](test/etx_tests.erl) | Tests on one node, with `ets` as the model |
| [test/etx_nodes_tests.erl](test/etx_nodes_tests.erl) | A test with three nodes |
