/*  Author:        Jan Wielemaker
    E-mail:        jan@swi-prolog.org
    WWW:           http://www.swi-prolog.org
    Copyright (c)  2025, SWI-Prolog Solutions b.v.
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module(lsp_client,
          [ ensure_lsp_server/4,     % +Buffer, +File, +Mode, -Sheet
            lsp_token_type/3,        % +LSP, ?TokenTypeNum, ?TokenTypeName
            lsp_client/2             % ?LSPClientObj, ?Stream
          ]).
:- use_module(library(pce)).
:- use_module(library(process)).
:- use_module(library(json_rpc_client)).
:- use_module(library(json_rpc_server)).
:- use_module(library(apply)).
:- use_module(library(broadcast)).
:- use_module(library(debug)).
:- use_module(library(lists)).
:- use_module(library(pce_util)).
:- use_module(library(uri)).

:- use_module(lsp_registry).

%!  lsp_token_type(+LSP, ?TokenTypeNum, ?TokenTypeName)

lsp_token_type(LSP, TokenTypeNum, TokenTypeName) :-
    token_type(LSP, TokenTypeNum, TokenTypeName).

                /*******************************
                *     CLASS LSP WORKSPACE      *
                *******************************/

:- pce_begin_class(lsp_workspace, object,
                   "Represent a workspace").

:- dynamic
    lsp_workspace/2.                            % Dir, Object

variable(root,	      directory,  get, "Workspace root").
variable(lsp_clients, sheet,     none, "Mode -> chain(LSP client)").

initialise(WS, Root:root=directory) :->
    "Create a workspace from its root"::
    send_super(WS, initialise),
    send(WS, slot, root, Root),
    send(WS, slot, lsp_clients, new(sheet)),
    get(Root, path, FullDir),
    asserta(lsp_workspace(FullDir, WS)).

lookup(_Ctx, Root:directory, WS:lsp_workspace) :<-
    "Lookup existing workspace from directory"::
    get(Root, path, FullDir),
    lsp_workspace(FullDir, WS).

unlink(WS) :->
    retractall(lsp_workspace(_, WS)),
    send_super(WS, unlink).

%!  ensure_lsp_server(+Buffer, +File, +Mode, -Sheet) is semidet.
%
%   True when sheet is a mapping Id->LSPClient for the clients
%   to use for Buffer.

ensure_lsp_server(Buffer, _File, _Mode, Clients) :-
    get(Buffer, attribute, lsp_clients, Clients),
    !.
ensure_lsp_server(Buffer, File, Mode, Clients) :-
    file_workspace(File, Mode, Workspace),
    get(Workspace, lsp_clients, Mode, Clients),
    send(Buffer, attribute, lsp_clients, Clients).

%!  file_workspace(+File, +Mode, -WorkSpace) is det.
%
%   Find or create a workspace for File in Mode.

file_workspace(File, _, WorkSpace) :-
    parent_directory(File, Parent),
    lsp_workspace(Parent, WorkSpace),
    !.
file_workspace(File, Mode, WorkSpace) :-
    project_root(File, Root, [mode(Mode)]),
    new(WorkSpace, lsp_workspace(Root)).

parent_directory(Dir, Dir).
parent_directory(Dir, Parent) :-
    file_directory_name(Dir, Direct),
    Direct \== Dir,
    parent_directory(Direct, Parent).

%   <-lsp_clients
%
%   Associate relevant LSP clients  to  a   mode.  The  LSP  clients are
%   organised in a sheet, mapping the  primary   id  to the client. This
%   allows modes to dispatch certain LSP   services  to specific clients
%   based on the client id.

lsp_clients(WS, Mode:name, Clients:sheet) :<-
    "Get or create LSP clients for mode"::
    get(WS, slot, lsp_clients, Sheet),
    (   get(Sheet, value, Mode, Clients)
    ->  true
    ;   new(Clients, sheet),
        lsp_create_client(WS, Mode, Id, Client),
        send(Clients, value, Id, Client),
        send(Sheet, value, Mode, Clients)
    ).

lsp_create_client(WS, Mode, Id, LSP) :-
    get(WS?root, path, Root),
    lsp_server(Id, Root, Config),
    memberchk(Mode, Config.modes),
    new(LSP, lsp_client(Id, WS,
                        Config.executable,
                        Config.get(arguments,[]))),
    send(LSP, start).

:- pce_end_class.



                /*******************************
                *       CLASS LSP CLIENT       *
                *******************************/

%!  lsp_client(?LSPClientObj, ?Stream)

:- dynamic
    lsp_client/2.                               % ?Client, ?Stream

:- at_halt(disconnect_lsps).

disconnect_lsps :-
    forall(retract(lsp_client(LSP, _Stream)),
           send(LSP, free)).

:- pce_begin_class(lsp_client, object,
                   "Connect to an LSP server").

variable(id,		name,          get, "LSP identifier").
variable(workspace,	lsp_workspace, get, "Workspace root").
variable(program,	prolog,	       get, "LSP excutable").
variable(arguments,	vector,        get, "LSP excutable arguments").
variable(connection,	prolog*,       get, "The connecting stream").

initialise(LSP, Id:name, Workspace:workspace=lsp_workspace,
           Program:program=prolog, Argv:arguments=[vector]) :->
    send_super(LSP, initialise),
    send(LSP, slot, id, Id),
    send(LSP, slot, workspace, Workspace),
    send(LSP, slot, program, Program),
    default(Argv, vector, TheArgv),
    send(LSP, slot, arguments, TheArgv).

unlink(LSP) :->
    clean_capabilities(LSP),
    send(LSP, disconnect),
    send_super(LSP, unlink).

start(LSP) :->
    "Connect and initialize"::
    send(LSP, connect),
    send(LSP, init).

connect(LSP) :->
    "Start the LSP server"::
    get(LSP, program, Prog),
    get_object(LSP, arguments, Vector),
    Vector =.. [vector|Argv],
    (   compound(Prog)
    ->  Exe = Prog
    ;   is_absolute_file_name(Prog)
    ->  Exe = Prog
    ;   Exe = path(Prog)
    ),
    process_create(Exe,
                   Argv,
                   [ stdin(pipe(In)),
                     stdout(pipe(Out)),
                     detached(true)
                   ]),
    stream_pair(Stream, Out, In),
    send(LSP, slot, connection, Stream),
    client_thread_alias(LSP, Alias),
    json_full_duplex(Stream,
                     [ header(true),
                       thread_alias(Alias)
                     ]),
    asserta(lsp_client(LSP, Stream)).


client_thread_alias(LSP, Alias) :-
    get(LSP, id, Id),
    get(LSP?workspace?root, path, Root),
    format(atom(Alias), '~w@~w', [Id, Root]).

disconnect(LSP) :->
    "Stop the connection"::
    (   get(LSP, connection, Stream),
        is_stream(Stream)
    ->  retractall(lsp_client(LSP, _)),
        ignore(get(LSP, call, shutdown, _Reply)), % Reply should be `null`
        ignore(send(LSP, notify, exit)),
        close(Stream, [force(true)]),
        send(LSP, slot, connection, @nil)
    ;   true
    ).

call(LSP, Message:message=prolog, Options:options=[prolog],
     Result:prolog) :<-
    "Make a JSON RPC call"::
    default(Options, [], TheOptions),
    get(LSP, connection, Stream),
    catch(json_call(Stream, Message, Result,
                    [ header(true)
                    | TheOptions
                    ]),
          Error,
          rpc_error(Error)).

notify(LSP, Message:message=prolog) :->
    "Send a JSON RPC notification"::
    get(LSP, connection, Stream),
    catch(json_notify(Stream, Message,
                      [ header(true)
                      ]),
          Error,
          rpc_error(Error)).

rpc_error(Error) :-
    print_message(error, Error),
    fail.

init(LSP) :->
    "Initialize the LSP connection for a directory"::
    get(LSP?workspace?root, path, Dir),
    uri_file_name(URI, Dir),
    get(LSP, call,
        initialize(
            #{ capabilities:
                 #{ textDocument:
                      #{ semanticTokens:
                           #{ dynamicRegistration: false,
                              requests:
                                #{ full: true,
                                   range: false
                                 }
                            },
                         tokenTypes: [],
                         tokenModifiers: []
                       }
                  },
               rootUri: URI
             }),
        Result),
    clean_capabilities(LSP),
    catch_with_backtrace(register_capabilities(LSP, Result.capabilities),
                         E,
                         print_message(error, E)).

:- dynamic
    token_type/3,                         % LSP, TypeId, TypeName
    token_modifier/3.                     % LSP, ModId,  ModName

clean_capabilities(LSP) :-
    retractall(token_type(LSP,_,_)),
    retractall(token_modifier(LSP,_,_)).

register_capabilities(LSP, Capabilities) :-
    register_token_types(LSP, Capabilities.semanticTokensProvider.legend).

register_token_types(LSP, Legend) :-
    forall(nth0(Id, Legend.tokenTypes, String),
           ( atom_string(TokenType, String),
             assertz(token_type(LSP, Id, TokenType)))),
    forall(nth0(Id, Legend.tokenModifiers, String),
           ( atom_string(TokenModifier, String),
             assertz(token_modifier(LSP, Id, TokenModifier)))).

%   <-modifiers
%
%   Translate the token modifier mask into a list of modifier names.

modifiers(LSP, Mask:mask=int, Modifiers:prolog) :<-
    "Translate a modifier mask to a list of names"::
    token_mask_modifiers(LSP, Mask, 0, Modifiers).

:- det(token_mask_modifiers/4).
token_mask_modifiers(_, 0, _, []) :-
    !.
token_mask_modifiers(LSP, Mask, ModID, List) :-
    Bit is 1<<ModID,
    ModID1 is ModID+1,
    (   Mask /\ Bit =\= 0,
        token_modifier(LSP, ModID, H)
    ->  Mask1 is Bit /\ \Bit,
        List = [H|T],
        token_mask_modifiers(LSP, Mask1, ModID1, T)
    ;   token_mask_modifiers(LSP, Mask,  ModID1, List)
    ).

%   ->lsp_execute_command(+Command) is det.
%
%   Send a request to execute Command. While  this is a JSON RPC request
%   and must have an `id`, it is  normally not answered. The async(true)
%   option ensures we are not waiting for a response.

execute_command(LSP, Command:prolog) :->
    "Execute a command on the workspace"::
    get(LSP, call,
        'workspace/executeCommand'(
            #{ command: Command.command,
               arguments: Command.arguments
             }),
        [async(true)],
        _NoReply).

:- pce_end_class(lsp_client).


                /*******************************
                *            SERVER            *
                *******************************/

:- json_method
    'textDocument/publishDiagnostics'(
        #{ parameters:
           #{ diagnostics: true
            }
         }),
    'workspace/applyEdit'(
        #{ parameters:
           #{ edit: true
            }
         }) : true.

%!  lsp_calling(-LSP) is det.
%
%   True when the method is called from LSP.

:- det(lsp_calling/1).
lsp_calling(LSP) :-
    nb_current(json_rpc_stream, Stream),
    lsp_client(LSP, Stream).

uri_buffer(URIs, Buffer) :-
    uri_file_name(URIs, File),
    get(@emacs, file_buffer, File, Buffer),
    get(Buffer, attribute, lsp_tracking, URI),
    atom_string(URI, URIs).

%!  'textDocument/publishDiagnostics'(+Data)
%
%   Sent after we  send  a  didOpen   or  didChange  notification.  This
%   contains (warning) messages.

'textDocument/publishDiagnostics'(Data) :-
    (   debugging(lsp(diagnostics))
    ->  pp(Data)
    ;   true
    ),
    lsp_calling(LSP),
    #{ uri:URI, diagnostics: Diagnostics } :< Data,
    uri_buffer(URI, Buffer),
    !,
    send(Buffer, lsp_publish_diagnostics, LSP, Diagnostics).
'textDocument/publishDiagnostics'(_).

%!  'workspace/applyEdit'(+Data, -Result) is det.
%
%   Act on server initiated workspace edits.

'workspace/applyEdit'(Data, Result) :-
    (   debugging(lsp(edit))
    ->  pp(Data)
    ;   true
    ),
    (   catch(apply_edits(Data), Error, true)
    ->  (   var(Error)
        ->  Result = #{applied: true}
        ;   message_to_string(Error, Msg),
            Result = #{ applied: false,
                        failureReason: Msg
                      }
        )
    ;   Result = #{ applied: false,
                    failureReason: "Failed"
                  }
    ).

apply_edits(Data) :-
    dict_pairs(Data.edit.changes, _, Pairs),
    maplist(apply_edit, Pairs).

apply_edit(FileURI-Changes) :-
    uri_buffer(FileURI, Buffer),
    apply_buffer_changes(Buffer, Changes).
apply_edit(FileURI-Changes) :-
    uri_file_name(FileURI, File),
    new(Buffer, emacs_buffer(File)),
    apply_buffer_changes(Buffer, Changes).

%!  apply_buffer_changes(+Buffer, +Changes) is det.
%
%   Apply a set of edits. Each edit  has a `range` and `newText`. Ranges
%   are against the original document. We turn   the request into a dict
%   in PceEmacs coordinates, sort them and apply them backwards from the
%   end.

apply_buffer_changes(Buffer, Changes) :-
    in_pce_thread_sync(apply_buffer_changes_(Buffer, Changes)).

apply_buffer_changes_(Buffer, Changes) :-
    maplist(change_description(Buffer), Changes, Descriptions),
    sort(offset, >=, Descriptions, Ordered),
    maplist(apply_change(Buffer), Ordered),
    send(Buffer, mark_undo),
    broadcast(pce_emacs(changed(Buffer))).
%   delay(0.1, lsp_highlight(Buffer)).

change_description(Buffer, Change,
                   #{offset: StartOffset, length: Length, text:String}) :-
    #{ newText: String, range: Range } :< Change,
    #{ start:Start, end:End } :< Range,
    lsp_offset(Start, Buffer, StartOffset),
    lsp_offset(End, Buffer, EndOffset),
    Length is EndOffset-StartOffset.

apply_change(Buffer, #{offset: Start, length: Length, text:String}) :-
    debug(lsp(edit), '~p: ~p[~p] = ~p',
          [Buffer, Start, Length, String]),
    send(Buffer, delete, Start, Length),
    send(Buffer, insert, Start, String).

lsp_offset(#{line:Line, character:Char}, Buffer, Offset) =>
    get(Buffer, lsp_offset, Line, Char, Offset).

:- meta_predicate
    delay(+, 0).

delay(Time, Goal) :-
    new(T, timer(Time,
                 and(message(@prolog, call, prolog(Goal)),
                     message(@receiver, free)))),
    send(T, start, once).
