%% @doc The processes of one cluster on this node.
%%
%% The etx application starts one supervisor of this module for each
%% cluster of its environment. A cluster is a cluster of redwall: the
%% transaction system of FoundationDB, with peace in the role of the
%% coordinators.
%%
%% == Processes ==
%%
%% The supervisor starts these children, in this order:
%%
%% <ol>
%% <li>The coordinator of this node (`redwall_coordinator'), if the
%%   option `coordinators' names this node. A coordinator keeps the
%%   coordinated state in the directory `dir'.</li>
%% <li>A process that forms the peace cluster of the coordinators
%%   (`redwall_coordinator:form/1'), if this node has a coordinator. The
%%   process tries again every 100 ms until every coordinator has the
%%   configuration, starts an election, and ends.</li>
%% <li>The worker of this node (`redwall_worker'), with a candidate for
%%   the ClusterController. The ClusterController starts the LogServers
%%   and the process of each epoch on the workers.</li>
%% <li>The StorageServer of this node (`redwall_storage'). Each node has
%%   every key in ETS tables in memory, so a read does not leave the
%%   node. A StorageServer that starts without data copies the data from
%%   the StorageServer of another node with a coordinator, if one of
%%   them has data.</li>
%% </ol>
%%
%% == Options of a cluster ==
%%
%% <ul>
%% <li>`coordinators': the servers of the peace cluster, a list of
%%   `{Name, Node}'. Every node of the cluster has the same list. The
%%   default is one coordinator on this node, so the default is a cluster
%%   of one node.</li>
%% <li>`dir': the directory of the coordinator of this node. The default
%%   is a directory with the names of the cluster and of the node, below
%%   the cache directory of the user for `etx'.</li>
%% <li>`fresh': the supervisor deletes the data of the coordinator of this
%%   node before the start: the directory with the name of the server
%%   below `dir', and nothing else. The default is `false'. The option is
%%   for a cluster that starts as a new cluster.</li>
%% <li>`reset_after_log_loss': whether the cluster starts again without
%%   data after the loss of the LogServers of an epoch, for example after
%%   the stop of every node (`redwall_recovery', "Reset"). Without the
%%   option, redwall decides: it resets the database, because its
%%   LogServers keep their records in memory. With `false', such a
%%   cluster has no epoch, and a function of {@link etx} waits.</li>
%% <li>`logs' and `replication': the number of LogServers of an epoch, and
%%   the number of LogServers with each record. The defaults are 3 and
%%   2. In a cluster of several nodes, each LogServer of an epoch is on a
%%   node of its own, so an epoch has at most one LogServer for each node
%%   that runs. An epoch starts when 2 nodes run. In a cluster of one
%%   node, every LogServer is on that node.</li>
%% <li>`automatic_idempotency': each transaction has an idempotency id of
%%   redwall, so a transaction whose commit has no answer is not applied
%%   a second time. The default is `true'. With `false', a function of
%%   {@link etx} that writes can be applied two times.</li>
%% <li>`storage_copy': a StorageServer that starts without data copies
%%   the data from the StorageServer of another node. The default is
%%   `true'. With `false', it reads every record from the LogServers,
%%   which is not possible after the stops of two different nodes.</li>
%% <li>`storage': `false' starts no StorageServer on this node. The
%%   functions of {@link etx} on this node then read from the
%%   StorageServers of the other nodes by message.</li>
%% </ul>
%%
%% == Limitations ==
%%
%% <ul>
%% <li>A LogServer and a StorageServer of redwall keep their data in
%%   memory. The data of a table does not survive the stop of every node
%%   of its cluster.</li>
%% <li>After the stop of every node, a cluster starts again without its
%%   tables. The coordinators keep the coordinated state on disk, so the
%%   nodes form the same cluster again, and the recovery resets the
%%   database, because no LogServer of the last epoch runs. The same
%%   happens when 2 LogServers of one epoch are lost while other nodes
%%   run: the cluster continues without its tables.</li>
%% <li>A coordinator whose directory is lost while the other coordinators
%%   run does not become a member of the cluster again.</li>
%% </ul>
-module(etx_cluster).

-include("etx_eta.hrl").

-behaviour(supervisor).

-export([start_link/2, db/1, names/0, options/2, status/1]).
-export([init/1]).
-export([start_former/2, form/2, start_storage/2, proxy/1, storage/1, storages/1]).

-export_type([name/0, options/0]).

-type name() :: atom().

-type options() :: #{
    coordinators => [peace:server_id()],
    dir => file:name_all(),
    fresh => boolean(),
    reset_after_log_loss => boolean(),
    logs => pos_integer(),
    replication => pos_integer(),
    automatic_idempotency => boolean(),
    storage_copy => boolean(),
    storage => boolean()
}.

-define(FORM_RETRY_MS, 100).

-spec start_link(name(), options()) -> {ok, pid()} | {error, term()}.
start_link(Name, Options) when is_atom(Name), is_map(Options) ->
    supervisor:start_link(?MODULE, {Name, Options}).

%% @doc Returns the database of redwall for a cluster of this node. The
%% call raises `badarg' if this node does not run the cluster.
-spec db(name()) -> redwall:database().
db(Name) ->
    try ets:lookup(etx_registry, {cluster, Name}) of
        [{_, Db}] -> Db;
        [] -> error(badarg)
    catch
        error:badarg -> error(badarg)
    end.

%% @doc Returns the health of a cluster of this node, and its fault
%% tolerance in Erlang nodes (`redwall_status:status/1'). The call raises
%% `badarg' if this node does not run the cluster.
-spec status(name()) -> redwall_status:status().
status(Name) ->
    try ets:lookup(etx_registry, {status, Name}) of
        [{_, Options}] -> redwall_status:status(Options);
        [] -> error(badarg)
    catch
        error:badarg -> error(badarg)
    end.

%% @doc Returns the names of the clusters that this node runs.
-spec names() -> [name()].
names() ->
    try
        lists:sort([Name || [Name] <- ets:match(etx_registry, {{cluster, '$1'}, '_'})])
    catch
        error:badarg -> []
    end.

%% @doc Returns the options of a cluster with the defaults.
-spec options(name(), options()) -> options().
options(Name, Options) ->
    Coordinators = maps:get(coordinators, Options, [{process_name(Name, coordinator), node()}]),
    Defaults = #{
        coordinators => Coordinators,
        dir => filename:join(filename:basedir(user_cache, "etx"), lists:concat([Name, "@", node()])),
        fresh => false,
        logs => 3,
        replication => 2,
        automatic_idempotency => true,
        storage_copy => true,
        storage => true
    },
    maps:merge(Defaults, Options).

%% @private
init({Name, Options0}) ->
    Options = #{coordinators := Coordinators, dir := Dir} = options(Name, Options0),
    Mine = [Id || Id = {_Server, Node} <- Coordinators, Node =:= node()],
    %% The write-ahead log of peace keeps the files of a server in the
    %% directory `Name@Node' below `dir'. Only that directory is deleted.
    _ = [ok = delete(filename:join(Dir, lists:concat([Server, "@", Node]))) || maps:get(fresh, Options), {Server, Node} <- Mine],
    CoordinatorNodes = lists:usort([Node || {_Server, Node} <- Coordinators]),
    MinWorkers = min(2, length(CoordinatorNodes)),
    %% The options of `redwall_status:status/1' for `status/1'. The
    %% StorageServers of the cluster are the StorageServers that the
    %% workers have reported to the ClusterController.
    true = ets:insert(etx_registry, {{status, Name}, #{coordinators => Coordinators, min_workers => MinWorkers}}),
    Coordinator = [
        #{id => {coordinator, Id}, start => {redwall_coordinator, start_link, [#{id => Id, dir => Dir}]}}
     || Id <- Mine
    ],
    Former = [
        #{id => former, start => {?MODULE, start_former, [Id, Coordinators]}, restart => transient}
     || Id <- lists:sublist(Mine, 1)
    ],
    Worker = #{
        id => worker,
        start =>
            {redwall_worker, start_link, [
                #{
                    name => process_name(Name, worker),
                    coordinators => Coordinators,
                    %% A cluster of several nodes starts an epoch only
                    %% with the workers of 2 nodes. With one worker,
                    %% every LogServer of the epoch would be on one
                    %% node, and the stop of that node would end the
                    %% cluster.
                    candidate => (maps:with([logs, replication], Options))#{
                        min_workers => MinWorkers,
                        %% An option of the process of an epoch, for its
                        %% recovery.
                        proxy => maps:with([reset_after_log_loss], Options)
                    }
                }
            ]}
    },
    %% The StorageServer registers with the worker of the node, so the
    %% ClusterController has it in the list of the StorageServers of the
    %% cluster. A StorageServer that starts without data copies the data
    %% from another StorageServer of that list, if one of them has data.
    StorageOptions0 = #{coordinators => Coordinators, worker => process_name(Name, worker)},
    StorageOptions =
        case maps:get(storage_copy, Options) of
            true -> StorageOptions0;
            false -> StorageOptions0#{peers => []}
        end,
    Storage = [#{id => storage, start => {?MODULE, start_storage, [Name, StorageOptions]}} || maps:get(storage, Options)],
    true = ets:insert(
        etx_registry,
        {{cluster, Name},
            redwall:open(#{
                proxy => fun() -> ?MODULE:proxy(Name) end,
                storage => fun() -> ?MODULE:storages(Name) end,
                %% A transaction whose commit has no answer is not applied
                %% a second time.
                automatic_idempotency => maps:get(automatic_idempotency, Options),
                %% The keys of etx are lists. See "Keys in redwall" in
                %% `etx'.
                keys => list,
                profile => ets
            })}
    ),
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, Coordinator ++ Former ++ [Worker] ++ Storage}}.

%% @private
%% Starts the process that forms the peace cluster.
start_former(Id, Coordinators) ->
    proc_lib:start_link(?MODULE, form, [Id, Coordinators]).

%% @private
%% Forms the peace cluster of the coordinators, and starts an election on
%% the coordinator `Id' of this node, so that the cluster has a leader
%% without the wait for an election timeout. Every node with a coordinator
%% runs this function. Each call stores the same configuration.
form(Id, Coordinators) ->
    ok = proc_lib:init_ack({ok, self()}),
    form_loop(Id, Coordinators).

form_loop(Id, Coordinators) ->
    case redwall_coordinator:form(Coordinators, 1000) of
        ok ->
            ok = peace:trigger_election(Id);
        {error, _Reason} ->
            ok = timer:sleep(?FORM_RETRY_MS),
            form_loop(Id, Coordinators)
    end.

%% @private
%% Starts the StorageServer of a cluster, and records it in the registry.
start_storage(Name, Options) ->
    case redwall_storage:start_link(Options) of
        {ok, Pid} ->
            true = ets:insert(etx_registry, {{storage, Name}, Pid}),
            {ok, Pid};
        Error ->
            Error
    end.

%% @private
%% The process of the current epoch, from the information of the
%% ClusterController that the worker of this node has.
proxy(Name) ->
    case redwall_worker:db_info(process_name(Name, worker)) of
        #{proxies := [Process | _]} -> Process;
        _ -> undefined
    end.

%% @private
%% The StorageServer of the cluster on this node. A node without a
%% StorageServer has the StorageServers of the other nodes, from the
%% information of the ClusterController that the worker of this node has,
%% and reads from them by message.
storage(Name) ->
    case ets:lookup(etx_registry, {storage, Name}) of
        [{_, Pid}] -> Pid;
        [] -> redwall_worker:storages(process_name(Name, worker))
    end.

%% @private
%% The StorageServers of a database: the StorageServer of this node, and
%% after it the StorageServers of the other nodes. A read uses the ETS
%% tables of the StorageServer of this node. When that StorageServer has
%% not applied the read version, for example after its start, the read
%% goes to the StorageServers by message.
storages(Name) ->
    Others =
        case redwall_worker:storages(process_name(Name, worker)) of
            undefined -> [];
            List -> List
        end,
    case ets:lookup(etx_registry, {storage, Name}) of
        [{_, Pid}] -> [Pid | Others -- [Pid]];
        [] when Others =:= [] -> undefined;
        [] -> Others
    end.

process_name(Name, Role) ->
    list_to_atom(lists:concat([etx_, Name, "_", Role])).

%% Deletes the directory of a coordinator with its files.
delete(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok
    end.
