# Example with three nodes

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
  the start. See [limitations.md](limitations.md).
