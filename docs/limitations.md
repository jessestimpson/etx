# Limitations

- With the cluster option `automatic_idempotency => false`, a function
  that writes can be applied two times, when the process of an epoch
  stops after a commit is durable and before the client has the answer.
  The default is `true`.
- The nodes of a cluster can be restarted one after another without the
  loss of the tables only with a wait between two restarts.
  `etx:status/0` reports when the next node can stop. See [status.md](status.md).
- `etx:status/0` reports the stop of nodes. It does not examine
  partitions, and its result is not the state of one moment.
- With one of three nodes, a cluster has no epoch, and a function waits.
  The tables are kept if that node runs until another node has started
  again, and if the second node stopped after the cluster had a new
  epoch. `etx:status/0` does not list the second node in `safe_to_stop`.
- A read on a node whose StorageServer has not applied the read
  version, for example while the StorageServer copies after its start,
  waits for that StorageServer for one third of 5 seconds with three
  nodes, and then goes to the StorageServer of another node.
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
