# Verification

## Dependencies

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

## Unit tests

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

## Simulation

`make dst` runs etx under the scheduler, the simulated network and the
simulated disk of [eta](https://github.com/jessestimpson/eta). The harness is
[dst/etx_dst.erl](../dst/etx_dst.erl).

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
| `final` | At the end of a run, the last client of each node has ended: a count and a read of every object, and `etx:status/0` reports the StorageServer of the node as current |
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
| Two of the three nodes stop, one at a time, and start again, one at a time. The second node stops after the cluster has a new epoch. One node then runs alone, and the cluster has no epoch in that time. Added on 2026-11-24, in a run of `make dst` whose 15 tests pass in 203 s, after the two fixes of that day | 60 seeds, 500 operations each | No violation: the last client of each node reads the accounts and every earlier write. In 30 runs one node ran alone, and in all 30 the two nodes started again before the end of the operations. In the other 30 runs the second node was not killed, because the cluster had no new epoch before the end of the operations. 6,341 transfers |
| Planted defect: the second node stops without a wait for the new epoch | Seeds from 1, runs with one node alone | Found at seed 1, `conservation`: the cluster resets the database, and a read does not find the accounts. The same seed passes with the wait |

The simulation found these problems on 2026-11-23:

| Problem | Status |
|---|---|
| A transaction is applied two times. The process of the epoch stops after the commit is durable and before the client has the answer. The client receives the error 1021, and `redwall:transactional/2` runs the transaction again | Fixed on 2026-11-23 with the idempotency ids of redwall, which etx uses for every transaction |
| A write without a read never ends after a recovery, when the transaction has an idempotency id. The transaction has a read conflict key and no read version, so the Resolver answers that it is too old. The three-node unit test found it | Fixed in redwall: such a transaction asks for a read version at its commit. The last client of a run now also writes without a read; without the fix, 16 seeds of 30 fail |
| A StorageServer waits for an ended epoch without an end, when no LogServer of that epoch can answer that it is stopped. 1 seed of 300 | Fixed in redwall: the StorageServer reads the coordinated state at every tenth interval and after a failed request |
| A read returns a part of the objects, or none. The read waits while the StorageServer of a restarted node copies, and has a read version below the version of the copy. The invariant `conservation` found it in 29 seeds of 100 during the work on the copy | Fixed in redwall before the copy was committed: such a read is answered with too old, and the client reads again |
| No StorageServer has the data after restarts of two nodes. A StorageServer that is cut off stays without data, answers that it is empty, and the restarted StorageServers then read a log that does not exist | Fixed in redwall: a StorageServer that makes no progress in an ended epoch copies from a peer that is ahead. The rolling runs also wait until every StorageServer has the data |
| With random loss of single messages, every commit of a cluster stops while every process runs, in 18 seeds of 40. redwall does not send a message to a LogServer again | Not fixed in redwall. The runs of etx lose no single message, because Erlang distribution does not lose a message of a connection that stays up. A partition ends a connection |
| After kills of two different nodes, one at a time and with a restart in between, a node does not answer, in 4 seeds of 60. A LogServer keeps its records in memory, so a record of an earlier epoch can then be on no LogServer, and a StorageServer that starts cannot read it | Fixed on 2026-11-24 for restarts that wait for a recovered cluster: a StorageServer that starts without data copies the data from the StorageServer of another node. A second kill before the cluster has recovered from the first still ends the cluster. See [limitations.md](limitations.md) |
| On a cluster without commits, the StorageServer of a node that starts again stays behind. It copies the data up to the Known Committed Version of another StorageServer, and that version rises only with a later record, so it can be a version of an earlier epoch whose LogServers do not run. Found on 2026-11-24 with three Erlang nodes on one computer, not by the simulation, whose clients commit all the time: the node was behind for more than 60 s, and was current after 5 commits on another node | Fixed in redwall: a StorageServer whose version is the end version of an ended epoch has that version as its Known Committed Version. In the same run after the fix, the node is current 5 ms after the first question |
| A read on a node whose StorageServer is behind does not return. A function of etx read from the StorageServer of its node only. Found in the same run: a lookup did not return in 60 s | Fixed: the database of a cluster has the StorageServer of its node first and the StorageServers of the other nodes after it. In the same run after the fix, a lookup on the node returns in 134 ms |

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
