-module(isolation_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

all() -> [{group, tests}].

% suite() -> [{timetrap, {seconds, 10}}].

groups() ->
    [
     {tests, [], [
        write_invisible_outside_transaction,
        delete_invisible_outside_transaction,
        unlock_on_transaction_exit,
        consistent_counter
        ]}].

init_per_suite(Config) ->
    PrivDir = ?config(priv_dir, Config),
    filelib:ensure_dir(PrivDir),
    mnevis:start(PrivDir),
    application:start(sasl),
    % mnevis_node:trigger_election(),
    Config.

end_per_suite(Config) ->
    ra:stop_server(mnevis_node:node_id()),
    application:stop(mnevis),
    application:stop(mnesia),
    application:stop(ra),
    Config.


init_per_testcase(_Test, Config) ->
    create_sample_table(),
    Config.

end_per_testcase(_Test, Config) ->
    delete_sample_table(),
    Config.


create_sample_table() ->
    delete_sample_table(),
    mnevis:create_table(sample, []),
    ok.

delete_sample_table() ->
    mnevis:delete_table(sample),
    ok.

add_sample(Key, Val) ->
    {atomic, ok} = mnevis:transaction(fun() ->
        mnesia:write({sample, Key, Val})
    end),
    {atomic, [{sample, Key, Val}]} = mnevis:transaction(fun() ->
        mnesia:read(sample, Key)
    end),
    ok.

write_invisible_outside_transaction(_Config) ->
    add_sample(foo, bar),
    Pid = self(),
    BackgroundTransaction = spawn_link(fun() ->
        mnevis:transaction(fun() ->
            %% Update foo key
            mnesia:write({sample, foo, baz}),
            %% Add a new key
            mnesia:write({sample, bar, baz}),
            Pid ! ready,
            receive stop -> ok
            end,
            timer:sleep(100)
        end)
    end),
    receive ready -> ok
    after 1000 -> error(background_transaction_not_ready)
    end,
    [{sample, foo, bar}] = mnesia:dirty_read(sample, foo),
    [] = mnesia:dirty_read(sample, bar),

    BackgroundTransaction ! stop.

delete_invisible_outside_transaction(_Config) ->
    add_sample(foo, bar),
    add_sample(bar, baz),
    Pid = self(),
    BackgroundTransaction = spawn_link(fun() ->
        mnevis:transaction(fun() ->
            mnesia:delete({sample, foo}),
            mnesia:delete_object({sample, bar, baz}),
            Pid ! ready,
            receive stop -> ok
            end,
            timer:sleep(100)
        end)
    end),
    receive ready -> ok
    after 1000 -> error(background_transaction_not_ready)
    end,
    [{sample, foo, bar}] = mnesia:dirty_read(sample, foo),
    [{sample, bar, baz}] = mnesia:dirty_read(sample, bar),
    BackgroundTransaction ! stop.

unlock_on_transaction_exit(_Config) ->
    Pid = self(),
    Locking = spawn(fun() ->
        mnevis:transaction(fun() ->
            mnesia:lock({sample, bar}, write),
            Pid ! ready,
            receive stop -> ok
            end
        end)
    end),

    Locked = spawn(fun() ->
        mnevis:transaction(fun() ->
            mnesia:lock({sample, bar}, write),
            Pid ! unlocked
        end)
    end),
    receive ready -> ok
    after 1000 -> error(background_transaction_not_ready)
    end,
    receive unlocked -> error(should_be_locked)
    after 1000 -> ok
    end,
    exit(Locking, die),
    receive unlocked -> ok
    after 1000 -> error(should_be_unlocked)
    end.


consistent_counter(_Config) ->
    add_sample(counter, 0),
    UpdateCounter = fun() ->
        timer:sleep(100),
        % ct:pal("Read ~p~n", [self()]),
        [{sample, counter, N}] = mnesia:read(sample, counter),
        timer:sleep(100),
        % ct:pal("Write ~p~n", [self()]),
        ok = mnesia:write({sample, counter, N+1}),
        % timer:sleep(100),
        ok
    end,
    % Spawn 100 updates
    Updates = [ spawn_link(fun() ->
                    {atomic, ok} = mnevis:transaction(UpdateCounter)
                end)
                || _ <- lists:seq(1, 100) ],
    % timer:sleep(600),
    ct:pal("Time: ~p~n", [timer:tc(fun() -> wait_for_finish(Updates) end)]),
    {atomic, ok} = mnevis:transaction(fun() ->
        [{sample, counter, 100}] = mnesia:read(sample, counter),
        ok
    end).

wait_for_finish([]) -> ok;
wait_for_finish([Pid | Pids]) ->
    case process_info(Pid) of
        undefined -> wait_for_finish(Pids);
        _ -> timer:sleep(100), wait_for_finish([Pid | Pids])
    end.


