% $legal:1594:
% 
% Copyright (c) 2011, Michael Lowell Roberts.  
% All rights reserved. 
% 
% Redistribution and use in source and binary forms, with or without 
% modification, are permitted provided that the following conditions are 
% met: 
% 
%   - Redistributions of source code must retain the above copyright 
%   notice, this list of conditions and the following disclaimer. 
% 
%   - Redistributions in binary form must reproduce the above copyright 
%   notice, this list of conditions and the following disclaimer in the 
%   documentation and/or other materials provided with the distribution.
%  
%   - Neither the name of the copyright holder nor the names of 
%   contributors may be used to endorse or promote products derived 
%   from this software without specific prior written permission. 
% 
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS 
% IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED 
% TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A 
% PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER 
% OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED 
% TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR 
% PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF 
% LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING 
% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS 
% SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
% 
% ,$

-module(process_pool).
-behaviour(gen_server).

% [mlr][todo] Name -> Id
% [mlr][todo] accept {PoolPid, ChildId} and {ppci, PoolPid, ChildId}.

-export([
      apply_within_child/4,
      call/2,
      cast/2,
      start_child/3,
      start_link/2,
      test/0
   ]).

-export(
   [init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, 
      code_change/3]).

-record(state, {
      pool_pid,
      governess_pid,
      children_by_name = dict:new(),
      children_by_pid = dict:new()
   }).

test() ->
   % [mlr][todo] i should put together a more elaborate test.
   application:start(sasl),
   application:start(supervision_tree),
   supervision_tree:start_link(defaults, 
      [{supervision_tree, process_pool, 
            [{registered_supervisor, {local, process_pool_test}}], 
            [{worker, {supervision_tree_test, start_link, []}, defaults}]}]),
   PoolPid = whereis(process_pool_test),
   {ok, ChildPid} = start_child(PoolPid, 0, defaults),
   ok = error_logger:info_report({child_started, {id, 0}, {pid, ChildPid}}),
   {ok, ChildPid} = find_child(PoolPid, 0),
   undefined = call({PoolPid, 0}, recall),
   ok = call({PoolPid, 0}, {store, 'o hai!'}),
   'o hai!' = call({PoolPid, 0}, recall),
   ok.

start_link(Options, [Child]) ->
   {ok, PoolPid} = supervision_tree:start_link(Options,
      [{supervisor,
            [{name, governess},
               {restart_strategy, simple_one_for_one}],
            [Child]},
         {worker, {gen_server, start_link, [process_pool, unused, []]},
            [{name, dispatch}]}]),
   ok = gen_server:cast(find_dispatch(PoolPid), {initialize, PoolPid}),
   {ok, PoolPid}.

init(unused) ->
   {ok, uninitialized}.

handle_call({call, ChildId, Message}, _From, State) ->
   {reply, call(State, ChildId, Message), State};
handle_call({find_child, ChildId}, _From, State) ->
   {reply, find_child(State, ChildId), State};
handle_call({apply_within_child, ChildId, Module, Function, Args}, _From, State) ->
   {reply, apply_within_child(State, ChildId, Module, Function, Args), State};
handle_call({start_child, Name, Args}, _From, State0) ->
   case start_child(State0, Name, Args) of
      {ok, Pid, State1} ->
         {reply, {ok, Pid}, State1};
      Other ->
         {reply, Other, State0}
   end;
handle_call(Request, From, _State) ->
   error({unexpected, {call, {request, Request}, {from, From}}}).

handle_cast({cast, ChildName, Message}, State) ->
   ok = cast(State, ChildName, Message),
   {noreply, State};
handle_cast({initialize, PoolPid}, State) ->
   {noreply, initialize(State, PoolPid)};
handle_cast(Msg, _State) ->
   error({unexpected, {cast, Msg}}).

handle_info(Info, _State) ->
   error({unexpected, {info, Info}}).

terminate(_Reason, _State) ->
   ok.

code_change(_OldVsn, State, _Extra) ->
   {ok, State}.

initialize(uninitialized, PoolPid) ->
   {ok, GovernessPid} = supervision_tree:find_child(PoolPid, governess),
   #state{pool_pid = PoolPid, governess_pid = GovernessPid}.

find_child(PoolPid, Name) when is_pid(PoolPid) ->
   gen_server:call(find_dispatch(PoolPid), {find_child, Name});
find_child(#state{} = State, Name) ->
   case dict:find(Name, State#state.children_by_name) of
      {ok, _} = Success ->
         Success;
      error ->
         {not_found, Name}
   end.

start_child(PoolPid, Name, Options) when is_pid(PoolPid) ->
   gen_server:call(find_dispatch(PoolPid), {start_child, Name, Options});
start_child(#state{} = State, Name, Options) ->
   case find_child(State, Name) of
      {ok, Pid} ->
         {redundant, {Name, Pid}};
      {not_found, Name} ->
         start_child2(State, Name, Options)
   end.

start_child2(State, Name, Options) ->
   ExtraArgs = supervision_tree_misc:find_option(args, Options, []),
   IdentifyArgs = 
      case supervision_tree_misc:find_option(identify, Options, false) of 
         false ->
            [];
         true ->
            [{pooled, State#state.pool_pid, Name}]
      end,
   {ok, Pid} = 
      supervisor:start_child(State#state.governess_pid, 
         IdentifyArgs ++ ExtraArgs),
   {ok, Pid, memorize_child(State, Name, Pid)}.

memorize_child(State, Name, Pid) ->
   State#state{
      children_by_name = dict:store(Name, Pid, State#state.children_by_name),
      children_by_pid = dict:store(Pid, Name, State#state.children_by_pid)}.

find_dispatch(PoolPid) ->
   {ok, DispatchPid} = supervision_tree:find_child(PoolPid, dispatch),
   DispatchPid.
   
apply_within_child({PoolPid, ChildId}, Module, Function, Args) ->
   gen_server:call(find_dispatch(PoolPid), 
      {apply_within_child, ChildId, Module, Function, Args}).

apply_within_child(State, ChildName, Module, Function, Args) ->
   case find_child(State, ChildName) of
      {ok, Pid} ->
         {ok, apply(Module, Function, [Pid | Args])};
      Other ->
         Other
   end.

cast({PoolPid, ChildId}, Message) ->
   ok = gen_server:cast(find_dispatch(PoolPid), 
      {cast, ChildId, Message}).

cast(State, ChildId, Message) ->
   case find_child(State, ChildId) of
      {ok, Pid} ->
         gen_server:cast(Pid, Message);
      {not_found, ChildId} ->
         % [mlr] in erlang, casts are dropped if the destination does not
         % exist. we honor that here as well.
         ok
   end.

call({PoolPid, ChildId}, Message) ->
   gen_server:call(find_dispatch(PoolPid), {call, ChildId, Message}, infinity).

call(State, ChildId, Message) ->
   case find_child(State, ChildId) of
      {ok, Pid} ->
         gen_server:call(Pid, Message);
      {not_found, ChildId} ->
         % [mlr] a failure to find the child is an out-of-band error condition.
         {noproc, {ppid, State#state.pool_pid, ChildId}}
   end.

% $vim:23: vim:set sts=3 sw=3 et:,$
