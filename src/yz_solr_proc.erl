%% -------------------------------------------------------------------
%%
%% Copyright (c) 2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(yz_solr_proc).
-include("yokozuna.hrl").
-compile(export_all).
-behavior(gen_server).

%% Keep compiler warnings away
-export([init/1,
         handle_info/2,
         terminate/2]).

-record(state, {
          dir=exit(dir_undefined),
          port=exit(port_undefined),
          solr_port=exit(solr_port_undefined)
         }).

-define(SHUTDOWN_MSG, "INT\n").
-define(S_MATCH, #state{dir=_Dir, port=_Port, solr_port=_SolrPort}).
-define(S_PORT(S), S#state.port).

%% @doc This module/process is responsible for administrating the
%%      external Solr/JVM OS process.

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(string(), string()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Dir, SolrPort) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Dir, SolrPort], []).


%%%===================================================================
%%% Callbacks
%%%===================================================================

%% NOTE: Doing the work here will slow down startup but I think that's
%%       desirable given that Solr must be up for Yokozuna to work
%%       properly.
init([Dir, SolrPort]) ->
    process_flag(trap_exit, true),
    Cmd = build_cmd(SolrPort, Dir),
    ?INFO("Starting solr: ~p", [Cmd]),
    Port = run_cmd(Cmd),
    wait_for_solr(solr_startup_wait()),
    S = #state{
      dir=Dir,
      port=Port,
      solr_port=SolrPort
     },
    {ok, S}.

handle_info({_Port, {data, Data}}, S=?S_MATCH) ->
    ?DEBUG("~p", Data),
    {noreply, S};

handle_info({exit_status, ExitStatus}, S) ->
    exit({"solr OS process exited", ExitStatus, S}).

terminate(_, S) ->
    Port = ?S_PORT(S),
    port_command(Port, ?SHUTDOWN_MSG),
    port_close(Port),
    ok.


%%%===================================================================
%%% Private
%%%===================================================================

build_cmd(SolrPort, Dir) ->
    Wrapper = filename:join([?YZ_PRIV, "sig-wrapper"]),
    Java = "java",
    SolrHomeArg = "-Dsolr.solr.home=" ++ Dir,
    JettyHomeArg = "-Djetty.home=" ++ Dir,
    PortArg = "-Djetty.port=" ++ SolrPort,
    LoggingProps = filename:join([Dir, "logging.properties"]),
    LoggingArg = "-Djava.util.logging.config.file=" ++ LoggingProps,
    LibDir = filename:join([?YZ_PRIV, "java_lib"]),
    LibArg = "-Dyz.lib.dir=" ++ LibDir,
    JarArg = "-jar " ++ filename:join([Dir, "start.jar"]),
    string:join([Wrapper, Java, JettyHomeArg, PortArg,
                 SolrHomeArg, LoggingArg, LibArg, JarArg], " ").

is_up() ->
    try
        _ = yz_solr:cores(),
        true
    catch throw:{error_calling_solr,core,_,_} ->
            false
    end.

run_cmd(Cmd) ->
    open_port({spawn, Cmd}, [exit_status]).

solr_startup_wait() ->
    app_helper:get_env(?YZ_APP_NAME,
                       solr_startup_wait,
                       ?YZ_DEFAULT_SOLR_STARTUP_WAIT).

wait_for_solr(0) ->
    throw({error, "Solr didn't start in alloted time"});
wait_for_solr(N) ->
    case is_up() of
        true ->
            ok;
        false ->
            timer:sleep(1000),
            wait_for_solr(N-1)
    end.
