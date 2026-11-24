%% @private
%% The supervisor of the etx application. It has one child for each
%% cluster of the application environment: a supervisor of
%% {@link etx_cluster}. It owns the table `etx_registry', which has the
%% database and the StorageServer of each cluster of this node.
-module(etx_sup).

-include("etx_eta.hrl").

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    etx_registry = ets:new(etx_registry, [named_table, public, {read_concurrency, true}]),
    Clusters = application:get_env(etx, clusters, #{}),
    Children = [
        #{id => Name, start => {etx_cluster, start_link, [Name, Options]}, type => supervisor}
     || {Name, Options} <- lists:sort(maps:to_list(Clusters))
    ],
    {ok, {#{strategy => one_for_one}, Children}}.
