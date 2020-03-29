%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at https://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2020 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_queue_consumers).

-include("rabbit.hrl").
-include("rabbit_framing.hrl").

-export([new/0, max_active_priority/1, inactive/1, all/1, count/0,
         unacknowledged_message_count/0, add/10, remove/3, erase_ch/2,
         send_drained/0, deliver/3, record_ack/3, subtract_acks/3,
         possibly_unblock/3,
         resume_fun/0, notify_sent_fun/1, activate_limit_fun/0,
         credit/6, utilisation/1]).

%%----------------------------------------------------------------------------

-define(UNSENT_MESSAGE_LIMIT,          200).

%% Utilisation average calculations are all in μs.
-define(USE_AVG_HALF_LIFE, 1000000.0).

-record(state, {consumers, use, order_key_state}).

-record(consumer, {tag, ack_required, prefetch, args, user}).

%% These are held in our process dictionary
-record(cr, {ch_pid,
             monitor_ref,
             acktags,
             consumer_count,
             %% Queue of {ChPid, #consumer{}} for consumers which have
             %% been blocked for any reason
             blocked_consumers,
             %% The limiter itself
             limiter,
             %% Internal flow control for queue -> writer
             unsent_message_count}).

-record(order_key_state, {order_key_consumers, ack_order_keys}).

-record(order_key_consumer, {q_entry, msg_count}).

-record(ack_order_key, {q_entry, order_key}).

%%-record(message, {routing_keys, id}).

%%----------------------------------------------------------------------------

-type time_micros() :: non_neg_integer().
-type ratio() :: float().
-type state() :: #state{consumers ::priority_queue:q(),
                        use       :: {'inactive',
                                      time_micros(), time_micros(), ratio()} |
                                     {'active', time_micros(), ratio()}}.
-type ch() :: pid().
-type ack() :: non_neg_integer().
-type cr_fun() :: fun ((#cr{}) -> #cr{}).
-type fetch_result() :: {rabbit_types:basic_message(), boolean(), ack()}.

-spec new() -> state().
-spec max_active_priority(state()) -> integer() | 'infinity' | 'empty'.
-spec inactive(state()) -> boolean().
-spec all(state()) -> [{ch(), rabbit_types:ctag(), boolean(),
                        non_neg_integer(), rabbit_framing:amqp_table(),
                        rabbit_types:username()}].
-spec count() -> non_neg_integer().
-spec unacknowledged_message_count() -> non_neg_integer().
-spec add(ch(), rabbit_types:ctag(), boolean(), pid(), boolean(),
          non_neg_integer(), rabbit_framing:amqp_table(), boolean(),
          rabbit_types:username(), state())
         -> state().
-spec remove(ch(), rabbit_types:ctag(), state()) ->
                    'not_found' | state().
-spec erase_ch(ch(), state()) ->
                      'not_found' | {[ack()], [rabbit_types:ctag()],
                                     state()}.
-spec send_drained() -> 'ok'.
-spec deliver(fun ((boolean()) -> {fetch_result(), T}),
              rabbit_amqqueue:name(), state()) ->
                     {'delivered',   boolean(), T, state()} |
                     {'undelivered', boolean(), state()}.
-spec record_ack(ch(), pid(), ack()) -> 'ok'.
-spec subtract_acks(ch(), [ack()], state()) ->
                           'not_found' | 'unchanged' | {'unblocked', state()}.
-spec possibly_unblock(cr_fun(), ch(), state()) ->
                              'unchanged' | {'unblocked', state()}.
-spec resume_fun()                       -> cr_fun().
-spec notify_sent_fun(non_neg_integer()) -> cr_fun().
-spec activate_limit_fun()               -> cr_fun().
-spec credit(boolean(), integer(), boolean(), ch(), rabbit_types:ctag(),
             state()) -> 'unchanged' | {'unblocked', state()}.
-spec utilisation(state()) -> ratio().

%%----------------------------------------------------------------------------

new() ->
    rabbit_log:info("rabbit_queue_consumers:new()"),
    #state{consumers = priority_queue:new(),
                use       = {active,
                             erlang:monotonic_time(micro_seconds),
                             1.0},
                order_key_state = #order_key_state{order_key_consumers = maps:new(),
                                                        ack_order_keys = maps:new()}
                }.

max_active_priority(#state{consumers = Consumers}) ->
    priority_queue:highest(Consumers).

inactive(#state{consumers = Consumers}) ->
    priority_queue:is_empty(Consumers).

all(#state{consumers = Consumers}) ->
    lists:foldl(fun (C, Acc) -> consumers(C#cr.blocked_consumers, Acc) end,
                consumers(Consumers, []), all_ch_record()).

consumers(Consumers, Acc) ->
    priority_queue:fold(
      fun ({ChPid, Consumer}, _P, Acc1) ->
              #consumer{tag = CTag, ack_required = Ack, prefetch = Prefetch,
                        args = Args, user = Username} = Consumer,
              [{ChPid, CTag, Ack, Prefetch, Args, Username} | Acc1]
      end, Acc, Consumers).

count() -> lists:sum([Count || #cr{consumer_count = Count} <- all_ch_record()]).

unacknowledged_message_count() ->
    lists:sum([queue:len(C#cr.acktags) || C <- all_ch_record()]).

add(ChPid, CTag, NoAck, LimiterPid, LimiterActive, Prefetch, Args, IsEmpty,
    Username, State = #state{consumers = Consumers,
                             use       = CUInfo}) ->
    C = #cr{consumer_count = Count,
            limiter        = Limiter} = ch_record(ChPid, LimiterPid),
    Limiter1 = case LimiterActive of
                   true  -> rabbit_limiter:activate(Limiter);
                   false -> Limiter
               end,
    C1 = C#cr{consumer_count = Count + 1, limiter = Limiter1},
    update_ch_record(
      case parse_credit_args(Prefetch, Args) of
          {0,       auto}            -> C1;
          {_Credit, auto} when NoAck -> C1;
          {Credit,  Mode}            -> credit_and_drain(
                                          C1, CTag, Credit, Mode, IsEmpty)
      end),
    Consumer = #consumer{tag          = CTag,
                         ack_required = not NoAck,
                         prefetch     = Prefetch,
                         args         = Args,
                         user          = Username},
    State#state{consumers = add_consumer({ChPid, Consumer}, Consumers),
                use       = update_use(CUInfo, active)}.

remove(ChPid, CTag, State = #state{consumers = Consumers, order_key_state = OrderKeyState}) ->
    case lookup_ch(ChPid) of
        not_found ->
            not_found;
        C = #cr{consumer_count    = Count,
                limiter           = Limiter,
                blocked_consumers = Blocked} ->
            Blocked1 = remove_consumer(ChPid, CTag, Blocked),
            Limiter1 = case Count of
                           1 -> rabbit_limiter:deactivate(Limiter);
                           _ -> Limiter
                       end,
            Limiter2 = rabbit_limiter:forget_consumer(Limiter1, CTag),
            update_ch_record(C#cr{consumer_count    = Count - 1,
                                  limiter           = Limiter2,
                                  blocked_consumers = Blocked1}),
            State#state{consumers = remove_consumer(ChPid, CTag, Consumers),
                    order_key_state = remove_order_key_consumer(ChPid, CTag, OrderKeyState)}
    end.

erase_ch(ChPid, State = #state{consumers = Consumers, order_key_state = OrderKeyState}) ->
    case lookup_ch(ChPid) of
        not_found ->
            not_found;
        C = #cr{ch_pid            = ChPid,
                acktags           = ChAckTags,
                blocked_consumers = BlockedQ} ->
            All = priority_queue:join(Consumers, BlockedQ),
            ok = erase_ch_record(C),
            Filtered = priority_queue:filter(chan_pred(ChPid, true), All),
            {[AckTag || {AckTag, _CTag} <- queue:to_list(ChAckTags)],
             tags(priority_queue:to_list(Filtered)),
             State#state{consumers = remove_consumers(ChPid, Consumers)
                    , order_key_state = remove_order_key_consumers(ChPid, OrderKeyState)}}
    end.

send_drained() -> [update_ch_record(send_drained(C)) || C <- all_ch_record()],
                  ok.

deliver(FetchFun, QName, State) -> deliver(FetchFun, QName, false, State).

deliver(FetchFun, QName, ConsumersChanged,
        State = #state{consumers = Consumers}) ->
    case priority_queue:out_p(Consumers) of
        {empty, _} ->
            {undelivered, ConsumersChanged,
             State#state{use = update_use(State#state.use, inactive)}};
        {{value, QEntry, Priority}, Tail} ->
            case deliver_to_consumer(FetchFun, QEntry, QName, State) of
                {delivered, R, State1} ->
                    {delivered, ConsumersChanged, R,
                     State1#state{consumers = priority_queue:in(QEntry, Priority,
                                                               Tail)}};
                undelivered ->
                    deliver(FetchFun, QName, true,
                            State#state{consumers = Tail})
            end
    end.

deliver_to_consumer(FetchFun, QEntry = {ChPid, Consumer}, QName, State) ->
    C = lookup_ch(ChPid),
    case is_ch_blocked(C) of
        true  -> block_consumer(C, QEntry),
                 undelivered;
        false -> case rabbit_limiter:can_send(C#cr.limiter,
                                              Consumer#consumer.ack_required,
                                              Consumer#consumer.tag) of
                     {suspend, Limiter} ->
                         block_consumer(C#cr{limiter = Limiter}, QEntry),
                         undelivered;
                     {continue, Limiter} ->
                         {R, State1} = deliver_to_consumer(FetchFun, Consumer,
                                                            C#cr{limiter = Limiter}, QEntry, QName, State),
                         {delivered, R, State1}
                 end
    end.

ensure_properties_decode(Message) ->
    #basic_message{content = Content} = Message,
    Content1 = rabbit_binary_parser:ensure_content_decoded(Content),
    Message#basic_message{content = Content1}.

get_headers(#basic_message{content = #content{properties = #'P_basic'{headers = Headers}}}) ->
    case Headers of
        undefined -> [];
        H         -> H
    end.

get_order_key(Message) ->
    Headers = get_headers(Message),
    case lists:keyfind(<<"x-order-key">>, 1, Headers) of
        false -> undefined;
        {_Key, _Type, Value} -> Value
    end.

deliver_to_consumer(FetchFun,
                    Consumer = #consumer{ack_required = AckRequired},
                    C, QEntry, QName,
                    State) ->
    {{Message, IsDelivered, AckTag}, R} = FetchFun(AckRequired),
    Message1 = ensure_properties_decode(Message),

%%    Headers = get_headers(Message1),
%%    lists:foreach(fun ({Key, _Type, Value}) ->
%%                        rabbit_log:info("rabbit_queue_consumers:deliver_to_consumer(key=~s, value=~s)", [Key, Value])
%%                  end, Headers),

    OrderKey = get_order_key(Message1),
    rabbit_log:info("rabbit_queue_consumers:deliver_to_consumer(OrderKey=~s)", [OrderKey]),

    State1 = case OrderKey of
        undefined ->
            rabbit_log:info("to rabbit_queue_consumers:deliver_message_to_consumer"),
            deliver_message_to_consumer(Message1, IsDelivered, AckTag,
                                        Consumer, C, QName),
            State;
        _ ->
            rabbit_log:info("to rabbit_queue_consumers:deliver_message_order_to_consumer"),
            deliver_message_order_to_consumer(Message1, IsDelivered, AckTag,
                                                Consumer, C,
                                                OrderKey, QEntry, QName, State)
    end,
    {R, State1}.

deliver_message_order_to_consumer(Message, IsDelivered, AckTag,
                                    Consumer, C,
                                    OrderKey, QEntry, QName, State=#state{order_key_state = OrderKeyState}) ->
    OrderKeyConsumer1 = case find_order_key_consumer(OrderKey, OrderKeyState) of
        {ok, #order_key_consumer{q_entry = QEntry1, msg_count = MsgCount}} ->
            if
                MsgCount < 50 ->
                    {ChPid1, Consumer1} = QEntry1,
                    C1 = lookup_ch(ChPid1),
                    rabbit_log:info("to rabbit_queue_consumers:deliver_message_to_consumer1"),
                    deliver_message_to_consumer(Message, IsDelivered, AckTag,
                        Consumer1, C1, QName),
                    #order_key_consumer{q_entry = QEntry1, msg_count = MsgCount + 1};
                true ->
                    rabbit_log:info("to rabbit_queue_consumers:deliver_message_to_consumer2"),
                    deliver_message_to_consumer(Message, IsDelivered, AckTag,
                        Consumer, C, QName),
                    #order_key_consumer{q_entry = QEntry, msg_count = 1}
            end;
        _ ->
            rabbit_log:info("to rabbit_queue_consumers:deliver_message_to_consumer3"),
            deliver_message_to_consumer(Message, IsDelivered, AckTag,
                Consumer, C, QName),
            #order_key_consumer{q_entry = QEntry, msg_count = 1}
    end,
    OrderKeyState1 = add_order_key_consumer(OrderKey, OrderKeyConsumer1, AckTag, OrderKeyState),
    State#state{order_key_state = OrderKeyState1}.

deliver_message_to_consumer(Message, IsDelivered, AckTag,
                            #consumer{tag           = CTag,
                                       ack_required  = AckRequired},
                            C = #cr{ch_pid                = ChPid,
                                    acktags               = ChAckTags,
                                    unsent_message_count  = Count},
                            QName) ->

    rabbit_channel:deliver(ChPid, CTag, AckRequired,
                          {QName, self(), AckTag, IsDelivered, Message}),
    ChAckTags1 = case AckRequired of
                      true  -> queue:in({AckTag, CTag}, ChAckTags);
                      false -> ChAckTags
                 end,
    update_ch_record(C#cr{acktags              = ChAckTags1,
                          unsent_message_count = Count + 1}).

record_ack(ChPid, LimiterPid, AckTag) ->
    C = #cr{acktags = ChAckTags} = ch_record(ChPid, LimiterPid),
    update_ch_record(C#cr{acktags = queue:in({AckTag, none}, ChAckTags)}),
    ok.

subtract_acks(ChPid, AckTags, State=#state{order_key_state = OrderKeyState}) ->
    case lookup_ch(ChPid) of
        not_found ->
            not_found;
        C = #cr{acktags = ChAckTags, limiter = Lim} ->

            %%判断Order开关
            State1 = State#state{order_key_state = remove_order_key_acks(AckTags, OrderKeyState)},

            {CTagCounts, AckTags2} = subtract_acks(
                                       AckTags, [], maps:new(), ChAckTags),
            {Unblocked, Lim2} =
                maps:fold(
                  fun (CTag, Count, {UnblockedN, LimN}) ->
                          {Unblocked1, LimN1} =
                              rabbit_limiter:ack_from_queue(LimN, CTag, Count),
                          {UnblockedN orelse Unblocked1, LimN1}
                  end, {false, Lim}, CTagCounts),
            C2 = C#cr{acktags = AckTags2, limiter = Lim2},
            case Unblocked of
                true  -> case unblock(C2, State1) of
                             unchanged -> {unchaned, State1};
                             {unblocked, State2} -> {unblocked, State2}
                         end;
                false -> update_ch_record(C2),
                    {unchanged, State1}
            end
    end.

subtract_acks([], [], CTagCounts, AckQ) ->
    {CTagCounts, AckQ};
subtract_acks([], Prefix, CTagCounts, AckQ) ->
    {CTagCounts, queue:join(queue:from_list(lists:reverse(Prefix)), AckQ)};
subtract_acks([T | TL] = AckTags, Prefix, CTagCounts, AckQ) ->
    case queue:out(AckQ) of
        {{value, {T, CTag}}, QTail} ->
            subtract_acks(TL, Prefix,
                          maps:update_with(CTag, fun (Old) -> Old + 1 end, 1, CTagCounts), QTail);
        {{value, V}, QTail} ->
            subtract_acks(AckTags, [V | Prefix], CTagCounts, QTail);
        {empty, _} ->
            subtract_acks([], Prefix, CTagCounts, AckQ)
    end.

possibly_unblock(Update, ChPid, State) ->
    case lookup_ch(ChPid) of
        not_found -> unchanged;
        C         -> C1 = Update(C),
                     case is_ch_blocked(C) andalso not is_ch_blocked(C1) of
                         false -> update_ch_record(C1),
                                  unchanged;
                         true  -> unblock(C1, State)
                     end
    end.

unblock(C = #cr{blocked_consumers = BlockedQ, limiter = Limiter},
        State = #state{consumers = Consumers, use = Use}) ->
    case lists:partition(
           fun({_P, {_ChPid, #consumer{tag = CTag}}}) ->
                   rabbit_limiter:is_consumer_blocked(Limiter, CTag)
           end, priority_queue:to_list(BlockedQ)) of
        {_, []} ->
            update_ch_record(C),
            unchanged;
        {Blocked, Unblocked} ->
            BlockedQ1  = priority_queue:from_list(Blocked),
            UnblockedQ = priority_queue:from_list(Unblocked),
            update_ch_record(C#cr{blocked_consumers = BlockedQ1}),
            {unblocked,
             State#state{consumers = priority_queue:join(Consumers, UnblockedQ),
                         use       = update_use(Use, active)}}
    end.

resume_fun() ->
    fun (C = #cr{limiter = Limiter}) ->
            C#cr{limiter = rabbit_limiter:resume(Limiter)}
    end.

notify_sent_fun(Credit) ->
    fun (C = #cr{unsent_message_count = Count}) ->
            C#cr{unsent_message_count = Count - Credit}
    end.

activate_limit_fun() ->
    fun (C = #cr{limiter = Limiter}) ->
            C#cr{limiter = rabbit_limiter:activate(Limiter)}
    end.

credit(IsEmpty, Credit, Drain, ChPid, CTag, State) ->
    case lookup_ch(ChPid) of
        not_found ->
            unchanged;
        #cr{limiter = Limiter} = C ->
            C1 = #cr{limiter = Limiter1} =
                credit_and_drain(C, CTag, Credit, drain_mode(Drain), IsEmpty),
            case is_ch_blocked(C1) orelse
                (not rabbit_limiter:is_consumer_blocked(Limiter, CTag)) orelse
                rabbit_limiter:is_consumer_blocked(Limiter1, CTag) of
                true  -> update_ch_record(C1),
                         unchanged;
                false -> unblock(C1, State)
            end
    end.

drain_mode(true)  -> drain;
drain_mode(false) -> manual.

utilisation(#state{use = {active, Since, Avg}}) ->
    use_avg(erlang:monotonic_time(micro_seconds) - Since, 0, Avg);
utilisation(#state{use = {inactive, Since, Active, Avg}}) ->
    use_avg(Active, erlang:monotonic_time(micro_seconds) - Since, Avg).

%%----------------------------------------------------------------------------

parse_credit_args(Default, Args) ->
    case rabbit_misc:table_lookup(Args, <<"x-credit">>) of
        {table, T} -> case {rabbit_misc:table_lookup(T, <<"credit">>),
                            rabbit_misc:table_lookup(T, <<"drain">>)} of
                          {{long, C}, {bool, D}} -> {C, drain_mode(D)};
                          _                      -> {Default, auto}
                      end;
        undefined  -> {Default, auto}
    end.

lookup_ch(ChPid) ->
    case get({ch, ChPid}) of
        undefined -> not_found;
        C         -> C
    end.

ch_record(ChPid, LimiterPid) ->
    Key = {ch, ChPid},
    case get(Key) of
        undefined -> MonitorRef = erlang:monitor(process, ChPid),
                     Limiter = rabbit_limiter:client(LimiterPid),
                     C = #cr{ch_pid               = ChPid,
                             monitor_ref          = MonitorRef,
                             acktags              = queue:new(),
                             consumer_count       = 0,
                             blocked_consumers    = priority_queue:new(),
                             limiter              = Limiter,
                             unsent_message_count = 0},
                     put(Key, C),
                     C;
        C = #cr{} -> C
    end.

update_ch_record(C = #cr{consumer_count       = ConsumerCount,
                         acktags              = ChAckTags,
                         unsent_message_count = UnsentMessageCount}) ->
    case {queue:is_empty(ChAckTags), ConsumerCount, UnsentMessageCount} of
        {true, 0, 0} -> ok = erase_ch_record(C);
        _            -> ok = store_ch_record(C)
    end,
    C.

store_ch_record(C = #cr{ch_pid = ChPid}) ->
    put({ch, ChPid}, C),
    ok.

erase_ch_record(#cr{ch_pid = ChPid, monitor_ref = MonitorRef}) ->
    erlang:demonitor(MonitorRef),
    erase({ch, ChPid}),
    ok.

all_ch_record() -> [C || {{ch, _}, C} <- get()].

block_consumer(C = #cr{blocked_consumers = Blocked}, QEntry) ->
    update_ch_record(C#cr{blocked_consumers = add_consumer(QEntry, Blocked)}).

is_ch_blocked(#cr{unsent_message_count = Count, limiter = Limiter}) ->
    Count >= ?UNSENT_MESSAGE_LIMIT orelse rabbit_limiter:is_suspended(Limiter).

send_drained(C = #cr{ch_pid = ChPid, limiter = Limiter}) ->
    case rabbit_limiter:drained(Limiter) of
        {[],         Limiter}  -> C;
        {CTagCredit, Limiter2} -> rabbit_channel:send_drained(
                                    ChPid, CTagCredit),
                                  C#cr{limiter = Limiter2}
    end.

credit_and_drain(C = #cr{ch_pid = ChPid, limiter = Limiter},
                 CTag, Credit, Mode, IsEmpty) ->
    case rabbit_limiter:credit(Limiter, CTag, Credit, Mode, IsEmpty) of
        {true,  Limiter1} -> rabbit_channel:send_drained(ChPid,
                                                         [{CTag, Credit}]),
                             C#cr{limiter = Limiter1};
        {false, Limiter1} -> C#cr{limiter = Limiter1}
    end.

tags(CList) -> [CTag || {_P, {_ChPid, #consumer{tag = CTag}}} <- CList].

add_consumer({ChPid, Consumer = #consumer{args = Args}}, Queue) ->
    Priority = case rabbit_misc:table_lookup(Args, <<"x-priority">>) of
                   {_, P} -> P;
                   _      -> 0
               end,
    priority_queue:in({ChPid, Consumer}, Priority, Queue).

remove_consumer(ChPid, CTag, Queue) ->
    priority_queue:filter(fun ({CP, #consumer{tag = CT}}) ->
                                  (CP /= ChPid) or (CT /= CTag)
                          end, Queue).

remove_consumers(ChPid, Queue) ->
    priority_queue:filter(chan_pred(ChPid, false), Queue).

add_order_key_consumer(OrderKey, OrderKeyConsumer=#order_key_consumer{q_entry = QEntry, msg_count = MsgCount}, AckTag,
        State = #order_key_state{order_key_consumers = OrderKeyConsumers, ack_order_keys = AckOrderKeys}) ->

    {_ChPid, #consumer{tag = CTag}} = QEntry,
    rabbit_log:info("rabbit_queue_consumers:add_order_key_consumer OrderKey=~s CTag=~s AckTag=~s MsgCount=~b"
                    , [OrderKey, CTag, AckTag, MsgCount]),
    State1 = State#order_key_state{order_key_consumers = maps:put(OrderKey, OrderKeyConsumer, OrderKeyConsumers)},
    State2 = State1#order_key_state{ack_order_keys = maps:put(AckTag,
                                                        #ack_order_key{q_entry = QEntry, order_key = OrderKey},
                                                        AckOrderKeys)},
    rabbit_log:info("rabbit_queue_consumers:add_order_key_consumer OrderKeyConsumers=~b AckOrderKeys=~b",
                    [maps:size(State2#order_key_state.order_key_consumers),
                        maps:size(State2#order_key_state.ack_order_keys)]),
    State2.


find_order_key_consumer(OrderKey, #order_key_state{order_key_consumers = OrderKeyConsumers}) ->
    maps:find(OrderKey, OrderKeyConsumers).

remove_order_key_ack(AckTag,
        State = #order_key_state{order_key_consumers = OrderKeyConsumers, ack_order_keys = AckOrderKeys}) ->
    State2 = case maps:find(AckTag, AckOrderKeys) of
        {ok, #ack_order_key{q_entry = QEntry, order_key = OrderKey}} ->
            {_ChPid, #consumer{tag = CTag}} = QEntry,
            State1 = case maps:find(OrderKey, OrderKeyConsumers) of
                {ok, OrderKeyConsumer = #order_key_consumer{msg_count = MsgCount}} ->
                    MsgCount1 = MsgCount - 1,
                    if
                        MsgCount1 == 0 ->
                            rabbit_log:info("rabbit_queue_consumers:remove_order_key_ack OrderKeyConsumers:remove OrderKey=~s CTag=~s AckTag=~b",
                                [OrderKey, CTag, AckTag]),
                            State#order_key_state{order_key_consumers = maps:remove(OrderKey, OrderKeyConsumers)};
                        true ->
                            rabbit_log:info("rabbit_queue_consumers:remove_order_key_ack OrderKeyConsumers:remove OrderKey=~s CTag=~s AckTag=~b MsgCount=~b",
                                [OrderKey, CTag, AckTag, MsgCount1]),
                            State#order_key_state{order_key_consumers = maps:put(OrderKey,
                                                OrderKeyConsumer#order_key_consumer{msg_count = MsgCount1},
                                                OrderKeyConsumers)}
                    end;
                _ -> State
            end,
            State1#order_key_state{ack_order_keys = maps:remove(AckTag, AckOrderKeys)};
        _ -> State
    end,
    rabbit_log:info("rabbit_queue_consumers:remove_order_key_ack OrderKeyConsumers=~b AckOrderKeys=~b",
                    [maps:size(State2#order_key_state.order_key_consumers),
                        maps:size(State2#order_key_state.ack_order_keys)]),
    State2.


remove_order_key_acks([], State) ->
    State;
remove_order_key_acks([T | TL], State) ->
    State1 = remove_order_key_ack(T, State),
    remove_order_key_acks(TL, State1).

remove_order_key_consumer(ChPid, CTag,
        State = #order_key_state{order_key_consumers = OrderKeyConsumers, ack_order_keys = AckOrderKeys}) ->
    OrderKeyConsumers1 = maps:filter(fun (_, #order_key_consumer{q_entry = {ChPid1, #consumer{tag = CTag1}}}) ->
                                        (ChPid1 /= ChPid) or (CTag1 /= CTag)
                                     end, OrderKeyConsumers),
    AckOrderKeys1 = maps:filter(fun (_, #ack_order_key{q_entry = {ChPid1, #consumer{tag = CTag1}}}) ->
                                    (ChPid1 /= ChPid) or (CTag1 /= CTag)
                                end, AckOrderKeys),
    State2 = State#order_key_state{order_key_consumers = OrderKeyConsumers1, ack_order_keys = AckOrderKeys1},
    rabbit_log:info("rabbit_queue_consumers:remove_order_key_consumers OrderKeyConsumers=~b AckOrderKeys=~b CTag=~s",
        [maps:size(State2#order_key_state.order_key_consumers),
            maps:size(State2#order_key_state.ack_order_keys), CTag]),
    State2.

remove_order_key_consumers(ChPid,
        State = #order_key_state{order_key_consumers = OrderKeyConsumers, ack_order_keys = AckOrderKeys}) ->
    OrderKeyConsumers1 = maps:filter(fun (_, #order_key_consumer{q_entry = {ChPid1, _}}) ->
                                        (ChPid1 /= ChPid)
                                     end, OrderKeyConsumers),
    AckOrderKeys1 = maps:filter(fun (_, #ack_order_key{q_entry = {ChPid1, _}}) ->
                                    (ChPid1 /= ChPid)
                                end, AckOrderKeys),
    State2 = State#order_key_state{order_key_consumers = OrderKeyConsumers1, ack_order_keys = AckOrderKeys1},
    rabbit_log:info("rabbit_queue_consumers:remove_order_key_consumers2 OrderKeyConsumers=~b AckOrderKeys=~b",
        [maps:size(State2#order_key_state.order_key_consumers),
            maps:size(State2#order_key_state.ack_order_keys)]),
    State2.

%%remove_all_order_key_consumers(State = #order_key_state{order_key_consumers = OrderKeyConsumers,
%%                                                        ack_order_keys = AckOrderKeys}) ->
%%    OrderKeyConsumers1 = maps:filter(fun (_, _) ->
%%                                        false
%%                                     end, OrderKeyConsumers),
%%    AckOrderKeys1 = maps:filter(fun (_, _) ->
%%                                    false
%%                                end, AckOrderKeys),
%%    State#order_key_state{order_key_consumers = OrderKeyConsumers1, ack_order_keys = AckOrderKeys1}.


chan_pred(ChPid, Want) ->
    fun ({CP, _Consumer}) when CP =:= ChPid -> Want;
        (_)                                 -> not Want
    end.

update_use({inactive, _, _, _}   = CUInfo, inactive) ->
    CUInfo;
update_use({active,   _, _}      = CUInfo,   active) ->
    CUInfo;
update_use({active,   Since,         Avg}, inactive) ->
    Now = erlang:monotonic_time(micro_seconds),
    {inactive, Now, Now - Since, Avg};
update_use({inactive, Since, Active, Avg},   active) ->
    Now = erlang:monotonic_time(micro_seconds),
    {active, Now, use_avg(Active, Now - Since, Avg)}.

use_avg(0, 0, Avg) ->
    Avg;
use_avg(Active, Inactive, Avg) ->
    Time = Inactive + Active,
    rabbit_misc:moving_average(Time, ?USE_AVG_HALF_LIFE, Active / Time, Avg).
