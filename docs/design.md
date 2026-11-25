# Design of etx

etx gives [redwall](https://github.com/jessestimpson/redwall) the
interface of `ets`. redwall is the transaction system. etx adds the
functions for tables and the start of a cluster from the application
environment.

## Tables

- A table is a key range of redwall. The key of an object in redwall is
  the list `[etx, Name, Key]`, and the objects of a table are the keys
  with the prefix `[etx, Name]`.
- A key and an object are Erlang terms. etx does not encode them. The
  order of the keys is the order of Erlang terms, as in an ETS table of
  the type `ordered_set`.
- `etx:open/1,2` creates the table if the cluster does not have it, and
  returns a handle. The handle is a term, so a handle of one node is a
  handle on every node of the cluster.

## Transactions

- A function with a handle of `open/2` is one transaction of redwall
  (`redwall:transactional/2`). For example, `update_counter/3` reads and
  writes in one transaction.
- `etx:transaction/2` runs a function with a handle that is bound to one
  transaction. Every function with that handle is a part of the
  transaction. With a list of handles of one cluster, the function
  receives a list of bound handles.
- A transaction that has a conflict runs again.
- Each transaction has an idempotency id of redwall
  (`automatic_idempotency`), so a transaction whose commit has no answer
  is not applied a second time.
- A match spec is evaluated in the StorageServer of redwall
  (`redwall:select/5`), so an object that does not match does not leave
  the StorageServer.
- Each node of a cluster has a StorageServer with the storage engine
  `ets` of redwall: every object is in ETS tables in memory. A read uses these tables in the process of the
  caller.

## Processes of a cluster

The application starts the processes of each cluster of the key
`clusters` on the node ([src/etx_cluster.erl](../src/etx_cluster.erl)).

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
