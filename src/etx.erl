%% @doc Erlang Term Transactions: tables with the interface of `ets' on
%% redwall.
%%
%% A table of etx has the functions of an ETS table of the type
%% `ordered_set'. The table is in a cluster of redwall, so every node of
%% the cluster has the same table, and each function is a transaction with
%% strict serializability. `open/2' takes the place of `ets:new/2'.
%%
%% == Example ==
%%
%% ```
%% %% sys.config: {etx, [{clusters, #{default => #{}}}]}
%% {ok, _} = application:ensure_all_started(etx),
%% T = etx:open(accounts),
%% true = etx:insert(T, [{alice, 10}, {bob, 5}]),
%% [{alice, 10}] = etx:lookup(T, alice),
%% 11 = etx:update_counter(T, alice, 1),
%% %% Several functions in one transaction.
%% ok = etx:transaction(T, fun(Tx) ->
%%     [{alice, A}] = etx:lookup(Tx, alice),
%%     [{bob, B}] = etx:lookup(Tx, bob),
%%     true = etx:insert(Tx, [{alice, A - 3}, {bob, B + 3}]),
%%     ok
%% end).
%% '''
%%
%% == Tables ==
%%
%% <ul>
%% <li>`open/2' creates the table if the cluster does not have it, and
%%   returns a handle. A second `open/2' with the same name, on any node,
%%   returns a handle of the same table. A table has no owner process, and
%%   stays until `delete/1'.</li>
%% <li>The handle is a term. A process can send it to a process of
%%   another node of the cluster.</li>
%% <li>An object is a tuple, and its key is the element `keypos'. A table
%%   has one object for each key. The keys are in the order of the Erlang
%%   terms.</li>
%% <li>A table is in one cluster. The option `{cluster, Name}' of `open/2'
%%   names it. The default is the cluster `default', or the only cluster
%%   of the node.</li>
%% </ul>
%%
%% == Transactions ==
%%
%% <ul>
%% <li>A function with a handle of `open/2' is one transaction. For
%%   example, `update_counter/3' reads and writes in one transaction, so
%%   two callers do not lose an update.</li>
%% <li>`transaction/2' runs a function with a handle that is bound to one
%%   transaction. Every function with that handle is a part of the
%%   transaction. With a list of handles of one cluster, the function
%%   receives a list of bound handles.</li>
%% <li>A transaction that has a conflict with another transaction runs
%%   again, so the function of `transaction/2' must give the same result
%%   when it runs several times. A transaction also runs again while the
%%   cluster has no epoch.</li>
%% <li>A read of a transaction returns the writes of the same
%%   transaction.</li>
%% <li>A transaction must end within 5 seconds, the MVCC window of
%%   redwall.</li>
%% </ul>
%%
%% == Keys in redwall ==
%%
%% The key of an object in redwall is the list `[etx, Name, Key]'. A key
%% of redwall is an Erlang term, so the key of an object is not encoded.
%% The keys of the objects of a table are the lists with the prefix
%% `[etx, Name]', which are one key range (`redwall_key:range/1'). The
%% options of a table are the value of the key `[etx_table, Name]'. The
%% database of a cluster has the option `keys => list' of redwall.
%%
%% == Differences from ets ==
%%
%% <ul>
%% <li>The types `bag' and `duplicate_bag' are not supported. `set' gives
%%   a table with ordered keys.</li>
%% <li>`open/2' does not fail for a table that exists. It raises `badarg'
%%   if the option `keypos' is not the `keypos' of the table.</li>
%% <li>The options of ets for access, heir, concurrency and compression
%%   are ignored.</li>
%% <li>`last/1' and `prev/2' read every key of the table below the result,
%%   because redwall has no read in the reverse order.</li>
%% <li>`info/2' with `size' counts the objects in the StorageServer.</li>
%% <li>A `select/3' with a limit and its `select/1' are several
%%   transactions if the handle is not bound to a transaction. They do not
%%   read one state of the table.</li>
%% <li>`update_counter' has the forms with an increment, with
%%   `{Pos, Incr}', with `{Pos, Incr, Threshold, SetValue}', and with a
%%   list of them.</li>
%% <li>These functions of ets are missing: `rename/2', `give_away/3',
%%   `setopts/2', `safe_fixtable/2', `slot/2', `fun2ms/1', `file2tab',
%%   `tab2file', `select_reverse', `select_replace', `first_lookup',
%%   `next_lookup', `whereis/1' and the functions for `dets'.</li>
%% </ul>
-module(etx).

-include("etx_eta.hrl").

-export([open/1, open/2, delete/1, info/1, info/2, clusters/0, transaction/2, status/0, status/1]).
-export([insert/2, insert_new/2, lookup/2, lookup_element/3, lookup_element/4, member/2, take/2]).
-export([delete/2, delete_object/2, delete_all_objects/1]).
-export([first/1, next/2, last/1, prev/2]).
-export([select/1, select/2, select/3, select_count/2, select_delete/2]).
-export([match/2, match_object/2, match_delete/2]).
-export([tab2list/1, foldl/3, foldr/3]).
-export([update_counter/3, update_counter/4, update_element/3]).

-export_type([table/0, continuation/0]).

-record(etx, {
    cluster :: etx_cluster:name(),
    name :: term(),
    keypos :: pos_integer(),
    %% The transaction of a handle of `transaction/2'.
    tx = none :: none | redwall:transaction()
}).

%% The key of the object of a row of redwall in a match spec: the third
%% element of the key of the row, which is the list `[etx, Name, Key]'.
-define(ROW_KEY, {hd, {tl, {tl, {element, 1, '$_'}}}}).

-opaque table() :: #etx{}.

-opaque continuation() :: {etx_continuation, table(), ets:match_spec(), pos_integer(), term()}.

-type option() :: {cluster, etx_cluster:name()} | {keypos, pos_integer()} | set | ordered_set | term().

%% ---------------------------------------------------------------------------
%% Tables
%% ---------------------------------------------------------------------------

%% @equiv open(Name, [])
-spec open(term()) -> table().
open(Name) ->
    open(Name, []).

%% @doc Returns a handle of the table `Name', and creates the table if the
%% cluster does not have it. See "Tables" in the module documentation.
-spec open(term(), [option()]) -> table().
open(Name, Options) when is_list(Options) ->
    _ = [error(badarg) || Type <- [bag, duplicate_bag], lists:member(Type, Options)],
    Cluster = proplists:get_value(cluster, Options, default_cluster()),
    Wanted = proplists:get_value(keypos, Options, undefined),
    _ = Wanted =:= undefined orelse (is_integer(Wanted) andalso Wanted > 0) orelse error(badarg),
    KeyPos = redwall:transactional(etx_cluster:db(Cluster), fun(Tx) ->
        case redwall:wait(redwall:get(Tx, [etx_table, Name])) of
            not_found ->
                New =
                    case Wanted of
                        undefined -> 1;
                        _ -> Wanted
                    end,
                ok = redwall:set(Tx, [etx_table, Name], #{keypos => New}),
                New;
            #{keypos := Stored} when Wanted =:= undefined; Wanted =:= Stored ->
                Stored;
            #{keypos := _Other} ->
                error(badarg)
        end
    end),
    #etx{cluster = Cluster, name = Name, keypos = KeyPos}.

%% @doc Deletes the table with its objects.
-spec delete(table()) -> true.
delete(T = #etx{name = Name}) ->
    run(T, fun(Tx) ->
        {Begin, End} = bounds(T),
        ok = redwall:clear_range(Tx, Begin, End),
        ok = redwall:clear(Tx, [etx_table, Name]),
        true
    end).

%% @doc Returns the names of the clusters that this node runs.
-spec clusters() -> [etx_cluster:name()].
clusters() ->
    etx_cluster:names().

%% @equiv status(default)
-spec status() -> redwall_status:status().
status() ->
    status(default_cluster()).

%% @doc Returns the health of a cluster, and its fault tolerance in Erlang
%% nodes. The result is the result of `redwall_status:status/1'.
%%
%% <ul>
%% <li>`healthy': the cluster has an epoch, and every coordinator, every
%%   LogServer of the epoch and every StorageServer runs and is
%%   current.</li>
%% <li>`fault_tolerance': `max_node_failures_without_losing_data' and
%%   `max_node_failures_without_losing_availability' are the numbers of
%%   nodes that can stop at the same time. `safe_to_stop' has the nodes
%%   whose stop alone leaves the cluster available.</li>
%% <li>`nodes': the processes of each node.</li>
%% <li>`problems': the reasons for which the cluster is not healthy.</li>
%% </ul>
%%
%% To restart the nodes of a cluster one after another, stop a node only
%% if it is in `safe_to_stop', and wait until `healthy' is `true' before
%% the next node.
-spec status(etx_cluster:name()) -> redwall_status:status().
status(Cluster) ->
    etx_cluster:status(Cluster).

-spec info(table()) -> [{atom(), term()}].
info(T) ->
    [{Item, info(T, Item)} || Item <- [name, cluster, type, keypos, size]].

-spec info(table(), name | cluster | type | keypos | size) -> term().
info(#etx{name = Name}, name) -> Name;
info(#etx{cluster = Cluster}, cluster) -> Cluster;
info(#etx{}, type) -> ordered_set;
info(#etx{keypos = KeyPos}, keypos) -> KeyPos;
info(T = #etx{}, size) -> select_count(T, [{'_', [], [true]}]);
info(#etx{}, _Item) -> error(badarg).

%% @doc Runs `Fun' in one transaction. `Fun' receives a handle that is
%% bound to the transaction, or a list of such handles for a list of
%% handles. The result is the result of `Fun'. See "Transactions" in the
%% module documentation.
-spec transaction(table() | [table()], fun((table() | [table()]) -> Result)) -> Result.
transaction(T = #etx{}, Fun) when is_function(Fun, 1) ->
    run(T, fun(Tx) -> Fun(T#etx{tx = Tx}) end);
transaction(Tables = [First = #etx{cluster = Cluster} | _], Fun) when is_function(Fun, 1) ->
    _ = [error(badarg) || Table <- Tables, not is_record(Table, etx) orelse Table#etx.cluster =/= Cluster],
    run(First, fun(Tx) -> Fun([Table#etx{tx = Tx} || Table <- Tables]) end).

%% ---------------------------------------------------------------------------
%% Objects
%% ---------------------------------------------------------------------------

-spec insert(table(), tuple() | [tuple()]) -> true.
insert(T, Object) when is_tuple(Object) ->
    insert(T, [Object]);
insert(T, Objects) when is_list(Objects) ->
    Rows = [{key(T, key_of(T, Object)), Object} || Object <- Objects],
    run(T, fun(Tx) ->
        lists:foreach(fun({Key, Object}) -> ok = redwall:set(Tx, Key, Object) end, Rows),
        true
    end);
insert(_T, _NoObject) ->
    error(badarg).

%% @doc Inserts the objects if the table has none of their keys.
-spec insert_new(table(), tuple() | [tuple()]) -> boolean().
insert_new(T, Object) when is_tuple(Object) ->
    insert_new(T, [Object]);
insert_new(T, Objects) when is_list(Objects) ->
    Rows = [{key(T, key_of(T, Object)), Object} || Object <- Objects],
    run(T, fun(Tx) ->
        case lists:all(fun({Key, _Object}) -> get(Tx, Key) =:= not_found end, Rows) of
            true ->
                lists:foreach(fun({Key, Object}) -> ok = redwall:set(Tx, Key, Object) end, Rows),
                true;
            false ->
                false
        end
    end);
insert_new(_T, _NoObject) ->
    error(badarg).

-spec lookup(table(), term()) -> [tuple()].
lookup(T, Key) ->
    run(T, fun(Tx) -> objects(get(Tx, key(T, Key))) end).

-spec lookup_element(table(), term(), pos_integer()) -> term().
lookup_element(T, Key, Pos) ->
    case lookup(T, Key) of
        [Object] when is_integer(Pos), Pos > 0, Pos =< tuple_size(Object) -> element(Pos, Object);
        _ -> error(badarg)
    end.

-spec lookup_element(table(), term(), pos_integer(), term()) -> term().
lookup_element(T, Key, Pos, Default) ->
    case lookup(T, Key) of
        [Object] when is_integer(Pos), Pos > 0, Pos =< tuple_size(Object) -> element(Pos, Object);
        [_Object] -> error(badarg);
        [] -> Default
    end.

-spec member(table(), term()) -> boolean().
member(T, Key) ->
    lookup(T, Key) =/= [].

%% @doc Returns the object of the key, and deletes it.
-spec take(table(), term()) -> [tuple()].
take(T, Key) ->
    run(T, fun(Tx) ->
        Found = objects(get(Tx, key(T, Key))),
        _ = [ok = redwall:clear(Tx, key(T, Key)) || _ <- Found],
        Found
    end).

-spec delete(table(), term()) -> true.
delete(T, Key) ->
    run(T, fun(Tx) ->
        ok = redwall:clear(Tx, key(T, Key)),
        true
    end).

-spec delete_object(table(), tuple()) -> true.
delete_object(T, Object) when is_tuple(Object) ->
    Key = key(T, key_of(T, Object)),
    run(T, fun(Tx) ->
        _ = get(Tx, Key) =:= Object andalso redwall:clear(Tx, Key),
        true
    end);
delete_object(_T, _NoObject) ->
    error(badarg).

-spec delete_all_objects(table()) -> true.
delete_all_objects(T) ->
    run(T, fun(Tx) ->
        {Begin, End} = bounds(T),
        ok = redwall:clear_range(Tx, Begin, End),
        true
    end).

%% ---------------------------------------------------------------------------
%% The order of the keys
%% ---------------------------------------------------------------------------

-spec first(table()) -> term() | '$end_of_table'.
first(T) ->
    {Begin, End} = bounds(T),
    run(T, fun(Tx) -> end_of_table(redwall:select(Tx, Begin, End, keys([]), [{limit, 1}])) end).

-spec next(table(), term()) -> term() | '$end_of_table'.
next(T, Key) ->
    {_Begin, End} = bounds(T),
    Spec = keys([{'>', '$1', {const, Key}}]),
    run(T, fun(Tx) -> end_of_table(redwall:select(Tx, key(T, Key), End, Spec, [{limit, 1}])) end).

%% @doc Returns the last key. The function reads every key of the table.
-spec last(table()) -> term() | '$end_of_table'.
last(T) ->
    {Begin, End} = bounds(T),
    run(T, fun(Tx) -> end_of_table(lists:reverse(redwall:select(Tx, Begin, End, keys([])))) end).

%% @doc Returns the key before `Key'. The function reads every key of the
%% table below `Key'.
-spec prev(table(), term()) -> term() | '$end_of_table'.
prev(T, Key) ->
    {Begin, _End} = bounds(T),
    run(T, fun(Tx) -> end_of_table(lists:reverse(redwall:select(Tx, Begin, key(T, Key), keys([])))) end).

end_of_table([Key | _]) -> Key;
end_of_table([]) -> '$end_of_table'.

%% A match spec for the rows of redwall that returns the key of each
%% object.
keys(Guards) ->
    [{{['_', '_', '$1'], '_'}, Guards, ['$1']}].

%% ---------------------------------------------------------------------------
%% Match specs
%% ---------------------------------------------------------------------------

%% @doc Returns the results of a match spec on the objects of the table,
%% in the order of the keys. The StorageServer of redwall evaluates the
%% match spec, so an object that does not match does not leave the
%% StorageServer. A match spec whose patterns all have a key without a
%% variable reads only those keys.
-spec select(table(), ets:match_spec()) -> [term()].
select(T, Spec) ->
    [Result || {_Key, Result} <- select_rows(T, Spec, infinity, none)].

%% @doc Returns the first `Limit' results and a continuation, or
%% `` '$end_of_table' ''.
-spec select(table(), ets:match_spec(), pos_integer()) -> {[term()], continuation()} | '$end_of_table'.
select(T, Spec, Limit) when is_integer(Limit), Limit > 0 ->
    chunk(T, Spec, Limit, none).

%% @doc Returns the next results of a `select/3'.
-spec select(continuation() | '$end_of_table') -> {[term()], continuation()} | '$end_of_table'.
select('$end_of_table') ->
    '$end_of_table';
select({etx_continuation, T, Spec, Limit, After}) ->
    chunk(T, Spec, Limit, {after_key, After}).

chunk(T, Spec, Limit, From) ->
    case select_rows(T, Spec, Limit, From) of
        [] ->
            '$end_of_table';
        Rows ->
            {Last, _Result} = lists:last(Rows),
            {[Result || {_Key, Result} <- Rows], {etx_continuation, T, Spec, Limit, Last}}
    end.

%% @doc Returns the number of objects for which the match spec returns
%% `true'.
-spec select_count(table(), ets:match_spec()) -> non_neg_integer().
select_count(T, Spec) ->
    length([true || {_Key, true} <- select_rows(T, Spec, infinity, none)]).

%% @doc Deletes the objects for which the match spec returns `true', and
%% returns their number.
-spec select_delete(table(), ets:match_spec()) -> non_neg_integer().
select_delete(T, Spec) ->
    run(T, fun(Tx) ->
        Keys = [Key || {Key, true} <- select_rows(T#etx{tx = Tx}, Spec, infinity, none)],
        lists:foreach(fun(Key) -> ok = redwall:clear(Tx, key(T, Key)) end, Keys),
        length(Keys)
    end).

-spec match(table(), ets:match_pattern()) -> [[term()]].
match(T, Pattern) ->
    select(T, [{Pattern, [], ['$$']}]).

-spec match_object(table(), ets:match_pattern()) -> [tuple()].
match_object(T, Pattern) ->
    select(T, [{Pattern, [], ['$_']}]).

-spec match_delete(table(), ets:match_pattern()) -> true.
match_delete(T, Pattern) ->
    _ = select_delete(T, [{Pattern, [], [true]}]),
    true.

-spec tab2list(table()) -> [tuple()].
tab2list(T) ->
    {Begin, End} = bounds(T),
    run(T, fun(Tx) -> [Object || {_Key, Object} <- redwall:get_range(Tx, Begin, End)] end).

%% @doc Calls `Fun' for each object in the order of the keys. The function
%% reads the objects in one transaction, and calls `Fun' after it.
-spec foldl(fun((tuple(), Acc) -> Acc), Acc, table()) -> Acc.
foldl(Fun, Acc, T) ->
    lists:foldl(Fun, Acc, tab2list(T)).

-spec foldr(fun((tuple(), Acc) -> Acc), Acc, table()) -> Acc.
foldr(Fun, Acc, T) ->
    lists:foldr(Fun, Acc, tab2list(T)).

%% The results of a match spec as `{Key, Result}', in the order of the
%% keys. `From' is `none', or `{after_key, Key}' for the objects after a
%% key.
select_rows(T, Spec, Limit, From) ->
    Options =
        case Limit of
            infinity -> [];
            _ -> [{limit, Limit}]
        end,
    case bound_keys(T, Spec) of
        {ok, Keys} ->
            %% Every pattern has its key. The objects of these keys are
            %% read, and the match spec runs in this process.
            Compiled = ets:match_spec_compile(with_key(T, Spec)),
            Wanted = [Key || Key <- lists:usort(Keys), From =:= none orelse Key > element(2, From)],
            Rows = run(T, fun(Tx) -> [{key(T, Key), Object} || Key <- Wanted, Object <- objects(get(Tx, key(T, Key)))] end),
            Results = ets:match_spec_run(Rows, Compiled),
            case Limit of
                infinity -> Results;
                _ -> lists:sublist(Results, Limit)
            end;
        scan ->
            {Begin0, End} = bounds(T),
            {Begin, Rewritten} =
                case From of
                    none -> {Begin0, with_key(T, Spec)};
                    {after_key, Key} -> {key(T, Key), after_key(Key, with_key(T, Spec))}
                end,
            run(T, fun(Tx) -> redwall:select(Tx, Begin, End, Rewritten, Options) end)
    end.

%% The keys of the patterns, if the key of every pattern has no variable.
bound_keys(#etx{keypos = KeyPos}, Spec) when is_list(Spec), Spec =/= [] ->
    Keys = [
        element(KeyPos, Head)
     || {Head, _Guards, _Body} <- Spec, is_tuple(Head), tuple_size(Head) >= KeyPos, ground(element(KeyPos, Head))
    ],
    case length(Keys) =:= length(Spec) of
        true -> {ok, Keys};
        false -> scan
    end;
bound_keys(_T, _Spec) ->
    scan.

%% The term of a pattern has no variable and no `_'.
ground('_') -> false;
ground(Atom) when is_atom(Atom) -> not is_variable(Atom);
ground(Tuple) when is_tuple(Tuple) -> ground(tuple_to_list(Tuple));
ground([Head | Tail]) -> ground(Head) andalso ground(Tail);
ground(Map) when is_map(Map) -> ground(maps:to_list(Map));
ground(_Other) -> true.

is_variable(Atom) ->
    case atom_to_list(Atom) of
        [$$ | Digits = [_ | _]] -> lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Digits);
        _ -> false
    end.

%% The match spec of the caller is for objects. A row of redwall is
%% `{[etx, Name, Key], Object}'. This function returns a match spec for
%% rows whose result is `{Key, Result}':
%%
%% <ul>
%% <li>The head `Head' becomes `{'_', Head}'.</li>
%% <li>`` '$_' '' in a guard or in the body becomes the second element of
%%   the row, which is the object.</li>
%% <li>The last expression of the body becomes a tuple of the key and of
%%   the expression.</li>
%% </ul>
with_key(_T, Spec) when is_list(Spec) ->
    [
        {
            {'_', Head},
            [object(Guard) || Guard <- guards(Guards)],
            [object(Expression) || Expression <- lists:droplast(Body)] ++
                [{{?ROW_KEY, object(lists:last(Body))}}]
        }
     || {Head, Guards, Body = [_ | _]} <- clauses(Spec)
    ];
with_key(_T, _NoList) ->
    error(badarg).

clauses(Spec) ->
    case lists:all(fun(Clause) -> is_tuple(Clause) andalso tuple_size(Clause) =:= 3 andalso is_list(element(3, Clause)) andalso element(3, Clause) =/= [] end, Spec) of
        true -> Spec;
        false -> error(badarg)
    end.

guards(Guards) when is_list(Guards) -> Guards;
guards(_NoList) -> error(badarg).

%% Replaces `` '$_' '' with the object of the row. A constant is not
%% changed.
object('$_') -> {element, 2, '$_'};
object({const, Term}) -> {const, Term};
object(Tuple) when is_tuple(Tuple) -> list_to_tuple([object(Element) || Element <- tuple_to_list(Tuple)]);
object([Head | Tail]) -> [object(Head) | object(Tail)];
object(Map) when is_map(Map) -> maps:map(fun(_Key, Value) -> object(Value) end, Map);
object(Other) -> Other.

%% Adds a guard for the rows after the key `Key'.
after_key(Key, Spec) ->
    [{Head, [{'>', ?ROW_KEY, {const, Key}} | Guards], Body} || {Head, Guards, Body} <- Spec].

%% ---------------------------------------------------------------------------
%% Updates
%% ---------------------------------------------------------------------------

%% @doc Adds to an element of the object of the key, and returns the new
%% value. The function raises `badarg' if the table does not have the
%% key.
-spec update_counter(table(), term(), integer() | tuple() | [tuple()]) -> integer() | [integer()].
update_counter(T, Key, Update) ->
    counter(T, Key, Update, none).

%% @doc `update_counter/3' with the object `Default' for a key that the
%% table does not have.
-spec update_counter(table(), term(), integer() | tuple() | [tuple()], tuple()) -> integer() | [integer()].
update_counter(T, Key, Update, Default) when is_tuple(Default) ->
    counter(T, Key, Update, {default, Default}).

counter(T = #etx{keypos = KeyPos}, Key, Update, Default) ->
    Ops =
        case Update of
            Incr when is_integer(Incr) -> [{KeyPos + 1, Incr}];
            Op when is_tuple(Op) -> [Op];
            List when is_list(List) -> List
        end,
    DKey = key(T, Key),
    run(T, fun(Tx) ->
        Object0 =
            case {get(Tx, DKey), Default} of
                {not_found, {default, New}} -> setelement(KeyPos, New, Key);
                {not_found, none} -> error(badarg);
                {Found, _} -> Found
            end,
        {Object, Results} = lists:foldl(
            fun(Op, {Acc, Values}) ->
                {Pos, Value} = count(Op, Acc, KeyPos),
                {setelement(Pos, Acc, Value), [Value | Values]}
            end,
            {Object0, []},
            Ops
        ),
        ok = redwall:set(Tx, DKey, Object),
        case Update of
            List1 when is_list(List1) -> lists:reverse(Results);
            _ -> hd(Results)
        end
    end).

count({Pos, Incr}, Object, KeyPos) when is_integer(Pos), is_integer(Incr), Pos > 0, Pos =< tuple_size(Object), Pos =/= KeyPos ->
    case element(Pos, Object) of
        Old when is_integer(Old) -> {Pos, Old + Incr};
        _ -> error(badarg)
    end;
count({Pos, Incr, Threshold, SetValue}, Object, KeyPos) when is_integer(Threshold), is_integer(SetValue) ->
    {Pos, Value} = count({Pos, Incr}, Object, KeyPos),
    case (Incr >= 0 andalso Value > Threshold) orelse (Incr < 0 andalso Value < Threshold) of
        true -> {Pos, SetValue};
        false -> {Pos, Value}
    end;
count(_Op, _Object, _KeyPos) ->
    error(badarg).

%% @doc Sets elements of the object of the key. The result is `false' if
%% the table does not have the key.
-spec update_element(table(), term(), {pos_integer(), term()} | [{pos_integer(), term()}]) -> boolean().
update_element(T, Key, Update = {_Pos, _Value}) ->
    update_element(T, Key, [Update]);
update_element(T = #etx{keypos = KeyPos}, Key, Updates) when is_list(Updates) ->
    DKey = key(T, Key),
    run(T, fun(Tx) ->
        case get(Tx, DKey) of
            not_found ->
                false;
            Object0 ->
                Object = lists:foldl(
                    fun
                        ({Pos, Value}, Acc) when is_integer(Pos), Pos > 0, Pos =< tuple_size(Acc), Pos =/= KeyPos -> setelement(Pos, Acc, Value);
                        (_Other, _Acc) -> error(badarg)
                    end,
                    Object0,
                    Updates
                ),
                ok = redwall:set(Tx, DKey, Object),
                true
        end
    end).

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

%% Runs `Fun' in the transaction of the handle, or in a new transaction.
run(#etx{tx = none, cluster = Cluster}, Fun) -> redwall:transactional(etx_cluster:db(Cluster), Fun);
run(#etx{tx = Tx}, Fun) -> Fun(Tx);
run(_NoTable, _Fun) -> error(badarg).

get(Tx, Key) ->
    redwall:wait(redwall:get(Tx, Key)).

objects(not_found) -> [];
objects(Object) -> [Object].

%% The key of an object in redwall.
key(#etx{name = Name}, Key) ->
    [etx, Name, Key].

%% The key range of the objects of a table: the lists with the prefix
%% `[etx, Name]'.
bounds(#etx{name = Name}) ->
    redwall_key:range([etx, Name]).

key_of(#etx{keypos = KeyPos}, Object) when is_tuple(Object), tuple_size(Object) >= KeyPos ->
    element(KeyPos, Object);
key_of(_T, _Object) ->
    error(badarg).

%% The cluster `default', or the only cluster of this node.
default_cluster() ->
    Names = etx_cluster:names(),
    case {lists:member(default, Names), Names} of
        {true, _} -> default;
        {false, [Only]} -> Only;
        _ -> error(badarg)
    end.
