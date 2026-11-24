# Status of a cluster

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
