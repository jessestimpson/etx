# etx

[![CI](https://github.com/jessestimpson/etx/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/jessestimpson/etx/actions/workflows/ci.yml)

etx (Erlang Term Transactions) is an Erlang application with the
interface of `ets` for a table that every node of a cluster shares.

- A table of etx has the functions of an ETS table of the type
  `ordered_set`.
- Each function is a transaction with strict serializability. When a
  call returns, a read on any node returns the new value.
- Each node has every object in memory, so a read does not leave the
  node.
- The transaction system is
  [redwall](https://github.com/jessestimpson/redwall), an implementation
  of the transaction system of FoundationDB in Erlang.

etx is experimental. etx uses the storage engine `ets` of redwall. With
this engine, the data of a table is in memory, and does not survive the
stop of every node of the cluster. See "Limitations".

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

`sys.config` for a cluster of three nodes, the same on each node:

```erlang
[{etx, [{clusters, #{
    default => #{
        coordinators => [{etx_c, 'a@host1'}, {etx_c, 'b@host2'}, {etx_c, 'c@host3'}],
        dir => "/var/lib/etx"
    }
}}]}].
```

A table that one node opens is a table of every node.
[docs/three-nodes.md](docs/three-nodes.md) has an example that starts
three nodes on one computer from `rebar3 shell`.

## Functions

`etx:open/1,2` takes the place of `ets:new/2`. The other functions have
the names, the arguments and the results of `ets`.

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

`etx:transaction/2` runs several functions in one transaction, on one
table or on a list of tables of one cluster.

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

## Fault tolerance

- With the defaults, each record of the log is on 2 LogServers on 2
  nodes, and each node has a copy of every object. A cluster of three
  nodes continues after the stop of one node. A function that runs at
  that time waits about 0.5 s for the new epoch.
- A node that starts again copies the data from another node.
- `etx:status/0` returns the health of a cluster, the number of nodes
  that can stop, and the nodes that are safe to stop. An operator uses
  it to restart the nodes one after another. See
  [docs/status.md](docs/status.md).
- After the stop of every node, or the loss of 2 LogServers of one
  epoch, the cluster starts again without its tables.

## Performance

`update_counter/3` takes about 140 us (p50) in a cluster of three nodes
on one computer, measured on 2026-11-23. The update is one transaction
of the cluster. A function of `ets` on one node takes less than 1 us.
etx has no benchmark in this repository.

## Verification

| Level | What it checks | Command |
|---|---|---|
| Unit tests | 13 tests. Random functions on a table of etx and on an ETS table give the same results. Transactions from several processes lose no update. A cluster of three Erlang nodes | `make test` |
| Simulation | 18 tests with about 800 seeds. Three nodes under the scheduler, the network and the disk of [eta](https://github.com/jessestimpson/eta), with kills and restarts of nodes and partitions. 8 invariants and 8 planted defects | `make dst` |

The verification of etx depends on the verification of
[redwall](https://github.com/jessestimpson/redwall):

- A function of etx is a transaction of redwall. The function has strict
  serializability only if a transaction of redwall has it.
- The tests of etx check the functions for tables, and a cluster of
  three nodes with kills and partitions. They do not repeat the
  verification of the transaction system: the models, the invariants of
  the simulation and the planted defects of redwall.
- redwall depends on [peace](https://github.com/jessestimpson/peace) in
  the same way, for the coordinated state.

The dependencies form a sequence: etx depends on redwall, and redwall
depends on peace. A result of a higher level holds only if the
verification of each level below it holds.

GitHub Actions runs both on each push to `main` and on each pull
request. See [docs/verification.md](docs/verification.md).

## Limitations

The most important limitations are:

- etx uses the storage engine `ets` of redwall, which keeps the data of
  a table in memory. After the stop of every node of a cluster, the
  cluster starts again without its tables. etx has no option for another
  storage engine.
- The nodes of a cluster can be restarted one after another without the
  loss of the tables only with a wait between two restarts.
  `etx:status/0` reports when the next node can stop.
- A transaction must end within 5 seconds.
- The function of `transaction/2` runs again after a conflict, so it
  must give the same result when it runs several times.
- A function waits without a limit of time while the cluster has no
  epoch.
- The types `bag` and `duplicate_bag` are not supported.
- The coordinators of a cluster cannot change.

[docs/limitations.md](docs/limitations.md) has the complete list, with
the functions of `ets` that are missing.

## Documentation

| Document | Contents |
|---|---|
| [docs/design.md](docs/design.md) | The keys of a table in redwall, the transactions, and the processes of a cluster on a node |
| [docs/three-nodes.md](docs/three-nodes.md) | An example with three nodes on one computer |
| [docs/status.md](docs/status.md) | The status of a cluster, and the restart of the nodes one after another |
| [docs/verification.md](docs/verification.md) | The unit tests, the simulation and its results |
| [docs/limitations.md](docs/limitations.md) | The complete list of limitations |

## Commands

| Command | Meaning |
|---|---|
| `make compile` | Compile |
| `make test` | Run the tests. The test with three nodes needs `epmd` |
| `make dst` | Run the simulation suite. Each test runs in an Erlang node of its own |

## Requirements

- Erlang/OTP 28
- rebar3
- redwall, from `https://github.com/jessestimpson/redwall.git`, at the
  commit that `rebar.lock` records
- peace, from `https://github.com/jessestimpson/peace.git`, at the commit
  that `rebar.lock` records
- eta, from `https://github.com/jessestimpson/eta.git`, for `make dst`, at
  the commit that the `dst` profile of `rebar.config` fixes. `rebar.lock`
  does not hold the dependencies of a profile.

rebar3 fetches the three applications. `rebar3 upgrade redwall` or
`rebar3 upgrade peace` moves the lock to the newest commit of the branch
`main`. For local development, a link at `_checkouts/redwall`,
`_checkouts/peace` or `_checkouts/eta` replaces the fetched application
with a local checkout.

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

## License

Apache License 2.0. See [LICENSE.md](LICENSE.md).
