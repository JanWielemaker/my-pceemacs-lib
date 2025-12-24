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

:- module(my_c_mode, []).
:- use_module(library(pce)).
:- use_module(library(emacs_extend), []).
:- use_module(library(process)).
:- use_module(library(json_rpc_client)).
:- use_module(library(json_rpc_server)).
:- use_module(library(uri)).
:- use_module(library(broadcast)).
:- use_module(library(debug)).
:- use_module(library(apply)).
:- use_module(library(pce_util)).
:- use_module(library(lists)).

:- use_module(lsp_symbol_item).
:- use_module(lsp_registry).

/** <module> A PceEmacs C mode based on the `clangd` LSP

This module implements an experimental C mode   based  on an LSP. In the
current state it is merely a _proof   of concept_, testing connecting an
LSP server to an PceEmacs mode.

Eventally, part of this should be moved   into  a reusable library. That
library should manage multiple LSP servers for multiple modes.
*/

%:- debug(lsp(file)).
%:- debug(lsp(highlight)).
%:- debug(lsp(project)).
%:- debug(lsp(log(verbose))).
%:- debug(lsp(changes)).
%:- debug(lsp(edit)).
%:- set_prolog_flag(debug_message_context, [time,thread]).

:- dynamic
    lsp_buffer/3.                               % URI, Buffer, LSP

:- initialization
    listen(pce_emacs(Event), lsp_event(Event)).

:- meta_predicate
    for_sheet(+, 2).

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

:- dynamic
    lsp_client/1.                               % -Client

:- at_halt(disconnect_lsps).

disconnect_lsps :-
    forall(retract(lsp_client(LSP)),
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
    send(LSP, slot, arguments, TheArgv),
    asserta(lsp_client(LSP)).

unlink(LSP) :->
    clean_capabilities(LSP),
    send(LSP, disconnect),
    send_super(LSP, unlink),
    retractall(lsp_client(_)).

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
    json_full_duplex(Stream,
                     [ header(true)
                     ]).

disconnect(LSP) :->
    "Stop the connection"::
    (   get(LSP, connection, Stream),
        is_stream(Stream)
    ->  ignore(get(LSP, call, shutdown, _Reply)), % Reply should be `null`
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

modifiers(LSP, Mask:mask=int, Modifiers:prolog) :<-
    "Translate a modifier mask to a list of names"::
    token_mask_modifiers(LSP, Mask, 0, Modifiers).

:- det(token_mask_modifiers/4).

token_mask_modifiers(_, 0, _, []) :-
    !.
token_mask_modifiers(LSP, Mask, ModID, List) :-
    Bit is 1<<ModID,
    ModID1 is ModID+1,
    (   Mask /\ Bit =\= 0
    ->  Mask1 is Bit /\ \Bit,
        List = [H|T],
        token_modifier(LSP, ModID, H),
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

%!  lsp_highlight(+TextBuffer, +LSPId) is semidet.
%
%   Do LSP based highlighting. Asks  for   the  tokens and applies them.
%   This seems to work fairly well, even for big files.

lsp_highlight(TB, LSP) :-
    get(TB, attribute, lsp_tracking, URI),
    send(TB, report, progress, 'LSP highlighting'),
    get_time(LSPTime0),
    get(LSP, call,
        'textDocument/semanticTokens/full'(
            #{ textDocument:
                 #{ uri: URI
                  }
             }),
        Result),
    get_time(LSPTime1),
    length(Result.data, Len),
    Tokens is Len//5,
    LSPTime is LSPTime1-LSPTime0,
    send(TB, report, progress,
         'Received %d semantic tokens in %.3f seconds', Tokens, LSPTime),
    send(TB, for_all_fragments,
         if(message(@arg1, instance_of, emacs_colour_fragment),
            message(@arg1, free))),
    get_time(FragmentTime0),
    highlight_tokens(Result.data, LSP, TB, 0, 0, 0, 0, Count),
    get_time(FragmentTime1),
    FragmentTime is FragmentTime1 - FragmentTime0,
    send(TB, report, progress,
         'Created %d fragments in %.3f seconds', Count, FragmentTime),
    send(TB, report, done).

%!  highlight_tokens(+DeltaTokens, +LSP, +Buffer, +StartLine, +StartPos,
%!                   +Offset, +Count0, -Count) is det.
%
%   @bug Offset inside the line is measured   in UTF-16 units by LSP. As
%   is, we use them as Unicode code points.

highlight_tokens([], _, _, _, _, _, C, C).
highlight_tokens([IL,IP,Len,Tid,Mid|More], LSP, TB, SL0, SP0, O0, C0, C) :-
    (   IL == 0
    ->  SL = SL0,
        SP is SP0+IP,
        Offset is O0+IP
    ;   SL is SL0+IL,
        SP = IP,
        get(TB, scan, O0, line, IL, start, SOL),
        Offset is SOL+IP
    ),
    token_type(LSP, Tid, TokenType),
    StyleClass = lsp(TokenType),
    (   style(StyleClass, _)
    ->  debug(lsp(token), '~p:~p[~p]@~p: ~p',
              [SL,SP,Len,Offset,TokenType]),
        style_name(StyleClass, StyleName),
        new(F, emacs_c_fragment(TB, Offset, Len, StyleName)),
        send(F, slot, lsp_client, LSP),
        send(F, slot, modifiers, Mid),
        C1 is C0+1
    ;   C1 = C0
    ),
    highlight_tokens(More, LSP, TB, SL, SP, Offset, C1, C).


%!  style(?Class, -Name, -Style) is nondet.
%
%   Define the styles.
%
%   @tbd Create a reusable library from similar  code used by the Prolog
%   mode  such  that  we  can  reduce    duplication  and  apply  themes
%   transparently.

style(Class, Name, Style) :-
    style(Class, Attributes),
    style_name(Class, Name),
    maplist(style_attribute, Attributes, PceArgs),
    (   PceArgs == []
    ->  Style = @default
    ;   Style =.. [style|PceArgs]
    ).

style_attribute(Attr, Name := Value) :-
    Attr =.. [Name,Value].

:- table style_name/2.
style_name(Class, Name) :-
    copy_term(Class, Copy),
    numbervars(Copy, 0, _, [singletons(true)]),
    term_string(Copy, S, [numbervars(true)]),
    atom_string(Name, S).

style(lsp(comment),    [colour(orange)]).              % There is a remark on this
style(lsp(variable),   [colour(red4)]).
style(lsp(parameter),  [colour(red4), underline(true)]).
style(lsp(function),   [bold(true)]).
style(lsp(macro),      [colour('#006e6e')]).
style(lsp(type),       [colour(blue), underline(true)]).
style(lsp(enumMember), [colour(magenta)]).
style(lsp(enum),       [colour(magenta), bold(true)]).
style(lsp(operator),   [colour(blue)]).

style(comment,         [colour(darkgreen)]).
style(quoted,          [colour(navyblue)]).
style(control,         [bold(true), colour(navyblue)]).
style(type,            [colour(blue)]).
style(qualifier,       [colour(blue)]).
style(definition,      [colour(blue)]).
style(operator,        [colour(blue)]).

style(lsp_diag_error,   [icon(Icon), underline(red)])      :- lsp_icon(error, Icon).
style(lsp_diag_warning, [icon(Icon), underline(orange)])   :- lsp_icon(warning, Icon).
style(lsp_diag_info,    [icon(Icon), underline(yellow)])   :- lsp_icon(info, Icon).
style(lsp_diag_hint,    [icon(Icon), underline(navyblue)]) :- lsp_icon(hint, Icon).

lsp_icon(error,   '64x64/lsp-error.png').
lsp_icon(warning, '64x64/lsp-warning.png').
lsp_icon(info,    '64x64/lsp-information.png').
lsp_icon(hint,    '64x64/lsp-hint.png').


                /*******************************
                *           CONNECT            *
                *******************************/

:- discontiguous
    lsp_event/1.

lsp_event(opened(Buffer)) :-
    get(Buffer, mode, Mode),
    get(Buffer, file, File),
    File \== @nil,
    get(File, path, Path),
    ensure_lsp_server(Buffer, Path, Mode, Clients),
    uri_file_name(URI, Path),
    debug(lsp(file), 'Opened ~p', [URI]),
    get(Buffer, contents, string(Content)),
    send(Buffer, attribute, lsp_version, 1),
    send(Buffer, attribute, lsp_tracking, URI),
    send(Buffer, lsp_changes, @on),
    for_sheet(Clients,
              document_open(URI, Buffer, Content)).

document_open(URI, Buffer, Content, _Id, LSP) :-
    assertz(lsp_buffer(URI, Buffer, LSP)),
    send(LSP, notify,
         'textDocument/didOpen'(
             #{textDocument:
                 #{ uri: URI,
                    languageId: "c",
                    version: 1,
                    text: Content
                  }
              })).

lsp_event(closed(Buffer)) :-
    get(Buffer, attribute, lsp_tracking, URI),
    debug(lsp(file), 'Closed ~p', [URI]),
    get(Buffer, attribute, lsp_clients, Clients),
    for_sheet(Clients,
              document_close(URI, Buffer)).

document_close(URI, Buffer, _Id, LSP) :-
    retractall(lsp_buffer(URI, Buffer, LSP)),
    send(LSP, notify,
         'textDocument/didClose'(
             #{textDocument:
                 #{ uri: URI
                  }
              })).

lsp_event(changed(Buffer)) :-
    get(Buffer, attribute, lsp_tracking, URI),
    get(Buffer, attribute, lsp_clients, Clients),
    get(Buffer, lsp_changes, Changes),
    get(Buffer, attribute, lsp_version, Version0),
    Version is Version0+1,
    send(Buffer, attribute, lsp_version, Version),
    (   Changes == @nil
    ->  get(Buffer, contents, string(Content)),
        JSONChanges = [ #{text: Content} ],
        debug(lsp(changes), 'Sending whole buffer for ~p', [Buffer]),
        send(Buffer, lsp_changes, @on)      % re-enable incremental
    ;   chain_list(Changes, ChangeList),
        maplist(to_json, ChangeList, JSONChanges),
        debug(lsp(changes), '~p: changes: ~@',
              [ Buffer,
                print_term(JSONChanges, [output(current_output)])
              ])
    ),
    for_sheet(Clients, document_changed(URI, Version, JSONChanges)).

document_changed(URI, Version, JSONChanges, _Id, LSP) :-
    send(LSP, notify,
         'textDocument/didChange'(
             #{ textDocument:
                  #{ uri: URI,
                     version: Version
                   },
                contentChanges: JSONChanges
              })).

to_json(Change, #{ range: #{ start: #{line: SL, character: SP},
                             end: #{line: EL, character: EP}
                           },
                   rangeLength: ULen,
                   text: Text
                 }) :-
    object(Change, text_change(SL, SP, EL, EP, TextObj)),
    get(Change, length, ULen),
    (   TextObj == @nil
    ->  Text = ""
    ;   object(TextObj, string(Text))
    ).

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

%!  'textDocument/publishDiagnostics'(+Data)
%
%   Sent after we  send  a  didOpen   or  didChange  notification.  This
%   contains (warning) messages.

'textDocument/publishDiagnostics'(Data) :-
    (   debugging(lsp(diagnostics))
    ->  pp(Data)
    ;   true
    ),
    #{ uri:URIs, diagnostics: Diagnostics } :< Data,
    atom_string(URI, URIs),
    lsp_buffer(URI, Buffer, LSP),
    !,
    send(Buffer, for_all_fragments,
         if(message(@arg1, instance_of, emacs_lsp_diagnostic),
            message(@arg1, free))),
    State = counts(0,0,0,0),
    maplist(show_diagnostic(Buffer, LSP, State), Diagnostics),
    report_diagnostic_counts(State, Buffer),
    debug(lsp(diagnostics), 'Counts: ~p', [State]).
'textDocument/publishDiagnostics'(_).

report_diagnostic_counts(Counts, Buffer) :-
    Counts = counts(E,W,I,H),
    send(Buffer, report, status, 'E: %d, W: %d, I: %d, H:%d', E,W,I,H),
    (   Counts == counts(0,0,0,0)
    ->  true
    ;   send(Buffer?editors, for_all,
             message(@arg1, margin_width, 22))
    ).

show_diagnostic(Buffer, LSP, State, Diagnostic) :-
    #{range: Range, severity: Severity} :< Diagnostic,
    #{start: Start, end: End} :< Range,
    lsp_offset(Start, Buffer, StartOffset),
    lsp_offset(End, Buffer, EndOffset),
    Length is EndOffset-StartOffset,
    lsp_severity_type(Severity, _Name, Style),
    step_count(Severity, State),
    new(D, emacs_lsp_diagnostic(Buffer, StartOffset, Length,
                                Diagnostic, Style)),
    send(D, slot, lsp_client, LSP).

lsp_offset(#{line:Line, character:Char}, Buffer, Offset) =>
    get(Buffer, lsp_offset, Line, Char, Offset).

step_count(Severity, State) :-
    arg(Severity, State, C0),
    C is C0+1,
    nb_setarg(Severity, State, C).

lsp_severity_type(1, error,   lsp_diag_error).
lsp_severity_type(2, warning, lsp_diag_warning).
lsp_severity_type(3, info,    lsp_diag_info).
lsp_severity_type(4, hint,    lsp_diag_hint).

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
    lsp_buffer(FileURI, Buffer, _LSP),
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

:- meta_predicate
    delay(+, 0).

delay(Time, Goal) :-
    new(T, timer(Time,
                 and(message(@prolog, call, prolog(Goal)),
                     message(@receiver, free)))),
    send(T, start, once).


                /*******************************
                *           FRAGMENT           *
                *******************************/

:- pce_begin_class(emacs_lsp_diagnostic, fragment,
                   "Represent an LSP diagnostic message").

variable(lsp_client, lsp_client*, get, "Source LSP client").
variable(json,       prolog,      get, "JSON diagnostic message").

initialise(F, Buffer:text_buffer, Start:int, Len:int,
           JSON:prolog, Style:name) :->
    "Create an LSP diagnostic fragment"::
    send_super(F, initialise, Buffer, Start, Len, Style),
    send(F, slot, json, JSON).

message(F, Msg:string) :<-
    "Diagnostic message"::
    get(F, json, Dict),
    Msg = Dict.get(message, "No message").

identify(F) :->
    "Show LSP message"::
    get(F, style, Style),
    style_pce_severity(Style, Severity, Label),
    send(F?text_buffer, report, Severity, '%s: %s', Label, F?message).

lsp_class(F, LspClass:{error,warning,info,hint}) :<-
    "Get severity class"::
    get(F, style, Style),
    style_pce_severity(Style, LspClass, _Label).

icon(F, Icon:image) :<-
    get(F, style, Style),
    lsp_severity_type(_Level, LspClass, Style),
    lsp_icon(LspClass, Icon).

fixes(F, Fixes:prolog) :<-
    "Get fixes from LSP server"::
    get(F, text_buffer, Buffer),
    get(Buffer, attribute, lsp_tracking, URI),
    get(F, json, Diagnostic),
    get(F, lsp_client, LSP),
    get(LSP, call,
        'textDocument/codeAction'(
            #{ textDocument: #{ uri: URI},
               range: Diagnostic.range,
               context: #{ diagnostics: [Diagnostic] }
             }),
        Fixes).


:- det(style_pce_severity/3).
style_pce_severity(lsp_diag_error,   error,   'Error').
style_pce_severity(lsp_diag_warning, warning, 'Warning').
style_pce_severity(lsp_diag_info,    status,  'Information').
style_pce_severity(lsp_diag_hint,    status,  'Hint').

:- pce_end_class.

:- pce_begin_class(emacs_c_fragment, emacs_colour_fragment,
                   "Represent an LSP highlight fragment").

variable(lsp_client,	lsp_client*, get, "Source LSP client").
variable(modifiers,	int := 0,    get, "LSP token type modifiers").

identify(F) :->
    "Identify LSP fragments"::
    get(F, style, StyleName),
    (   get(F, lsp_client, LSP),
        LSP \== @nil,
        get(F, modifiers, Mask),
        Mask \== 0
    ->  get(LSP, modifiers, Mask, Modifiers)
    ;   Modifiers = []
    ),
    term_string(Style, StyleName),
    phrase(c_fragment_message(Style, Modifiers), Codes),
    string_codes(String, Codes),
    send(F?text_buffer, report, status, '%s', String).

c_fragment_message(Style, Modifiers) -->
    token_style(Style),
    token_modifiers(Modifiers).

token_style(lsp(comment)) ==>
    "Inactive conditional".
token_style(lsp(Style)) ==>
    format('C ~w', [Style]).
token_style(comment) ==>
    "C comment".
token_style(Style) ==>
    format('~p', [Style]).

token_modifiers([]) ==>
    [].
token_modifiers(Modifiers) ==>
    format(' ~p', [Modifiers]).

format(Fmt, Args, Head, Tail) :-
    format(codes(Head, Tail), Fmt, Args).

:- pce_end_class.



                /*******************************
                *            C MODE            *
                *******************************/

:- emacs_extend_mode(c,
		     [ find_definition = key('\\e.'),
                       find_references = key('\\e?'),
                       goto_next_error = key('\\egn'),
                       goto_prev_error = key('\\egp')
		     ]).

class_variable(auto_colourise_size_limit, int, 400000).
class_variable(idle_timeout,              num, 0.3).

%!  role(+Role, -LSPId)

role(highlight, clangd).
role(symbol,    clangd).
role(complete,  clangd).

setup_mode(M) :->
    "Setup LSP based C mode"::
    send_super(M, setup_mode),
    (   get(M, attribute, lsp_clients, _)
    ->  send(M, setup_styles)
    ;   get(M, text_buffer, Buffer),
        lsp_event(opened(Buffer)),
        send(M, setup_styles),
        % needs to be called in next event cycle
        new(T, timer(0.1,
                     and(message(M, colourise_buffer),
                         message(@receiver, free)))),
        send(T, start, once),
        send(T, lock_object, @on)
    ).

setup_styles(M) :->
    "Initialize the editor style sheet"::
    get(M, editor, E),
    (   get(E, attribute, styles_assigned, @on)
    ->  true
    ;   forall(style(_Class, Name, Style),
               send(E, style, Name, Style)),
        send(E, attribute, styles_assigned, @on)
    ).

colourise_buffer(M) :->
    "Use LSP based highlighting"::
    get(M, text_buffer, TB),
    (   get(M, lsp_client, highlight, LSP),
        lsp_highlight(TB, LSP)
    ->  send(M, update_bookmarks)
    ;   send_super(M, colourise_buffer)
    ),
    send(M, highlight_c).

%   ->highlight_c
%
%   Perform basic C syntax highlighting.  This deals with comments
%   and C keyboards

highlight_c(M) :->
    "Basic C syntax highlighting"::
    get(M, text_buffer, TB),
    send(TB, for_all_syntax,
         message(M, highlight, @arg1, @arg2 - @arg1, @arg3)).

highlight(M, From:int, Len:int, Style:name) :->
    "Add a highlight fragment"::
    get(M, text_buffer, TB),
    adjust_style(Style, M, TB, From, Len, TheStyle),
    new(_, emacs_c_fragment(TB, From, Len, TheStyle)).

adjust_style(keyword, M, TB, From, Len, Style) =>
    get(TB, contents, From, Len, string(KeywordS)),
    atom_string(Keyword, KeywordS),
    get(M, keyword_type, Keyword, Style).
adjust_style(Style0, _M, _TB, _From, _Len, Style) =>
    Style = Style0.

%   <-lsp_client
%
%   Find the LSP client to implement a specific role for this mode.

lsp_client(M, Role:[name], LSP:lsp_client) :<-
    "Get the LSP server for this mode"::
    get(M, text_buffer, TB),
    get(TB, attribute, lsp_clients, Clients),
    (   Role == @default
    ->  get(Clients, '_arg', 1, attribute(_Role, LSP))
    ;   role(Role, LSPId),
        get(Clients, value, LSPId, LSP)
    ).

lsp_position(M, For:[int], Pos:prolog) :<-
    "Get LSP compatible position"::
    get(M, text_buffer, TB),
    get(TB, attribute, lsp_tracking, URI),
    (   For == @default
    ->  get(M, caret, Offset)
    ;   Offset = For
    ),
    get(TB, line_number, Offset, Line1),
    Line is Line1 - 1,
    get(TB, lsp_column, Offset, Col),
    Pos = #{ textDocument: #{ uri: URI },
             position: #{line:Line, character:Col}
           }.

on_symbol(M) :->
    "True if caret is on a symbol"::
    get(M, caret, Caret),
    (   Pos = Caret
    ;   Pos is Caret - 1
    ),
    get(M, character, Pos, Char),
    char_type(Char, alnum),
    !.

find_definition(M) :->
    "LSP based find definition"::
    (   get(M, lsp_client, symbol, LSP)
    ->  (   send(M, on_symbol)
        ->  send(M, find_symbol_at_caret, LSP)
        ;   send(M, noarg_call, goto_symbol)
        )
    ;   send(M, noarg_call, find_tag)
    ).

find_symbol_at_caret(M, LSP) :->
    "Find definition from current location"::
    get(M, lsp_position, Pos),
    get(LSP, call, 'textDocument/definition'(Pos), Result),
    send(M, lsp_goto, Result).

goto_symbol(M, Tag:symbol=lsp_tag) :->
    "Go to the definition of an LSP symbol"::
    get(M, lsp_client, symbol, LSP),
    get(LSP, call,
        'workspace/symbol'(
            #{ query: Tag
             }),
        Symbols),
    (   member(Symbol, Symbols),
        atom_string(Tag, Symbol.name)
    ->  send(M, lsp_goto, Symbol.location)
    ;   send(M, report, warning, 'Could not find LSP symbol %s', Tag)
    ).

lsp_goto(M, Location:prolog) :->
    " a location returned by the LSP server"::
    (   is_list(Location)
    ->  lsp_select_hit(Location, M, Hit)
    ;   Hit = Location
    ),
    send(M, save_word_location),
    get(M, word, Identifier),
    #{ uri:URI, range:Range } :< Hit,
    #{ start: Start, end:_End } :< Range,
    #{ line:SL, character: SP } :< Start,
    uri_file_name(URI, File),
    new(B, emacs_buffer(File)),
    get(B, open, tab, Frame),
    get(Frame, editor, Editor),
    get(B, lsp_offset, SL, SP, Offset),
    send(Editor, caret, Offset),
    new(Title, string('%s (definition)', Identifier)),
    send(Editor?mode, location_history, title := Title).

lsp_select_hit([Hit], _, Hit) :-
    !.
lsp_select_hit(Hits, M, _) :-
    format(string(String), '~p', [Hits]),
    send(M, report, warning, 'LSP Locations: %s', String),
    fail.

save_word_location(M) :->
    "Push the current word to the history"::
    get(M, text_buffer, TB),
    get(M, caret, Caret),
    get(TB, scan, Caret, word, 0, start, SW),
    get(TB, scan, Caret, word, 0, end, EW),
    WLen is EW-SW,
    get(TB, contents, SW, WLen, Identifier),
    new(Title, string('%s (use)', Identifier)),
    send(M, location_history, SW, WLen, always := @on, title := Title).

find_references(M) :->
    "Find references to symbol at caret"::
    get(M, lsp_position, Pos),
    get(M, lsp_client, symbol, LSP),
    get(LSP, call,
        'textDocument/references'(
            Pos.put(#{context:
                        #{ includeDeclaration: true }
                     })),
        References),
    get(M, word, Word),
    new(BM, emacs_bookmark_editor(string('References to %s', Word),
                                  @off)),
    length(References, Count),
    forall(member(Ref, References),
           add_lsp_reference(BM, Ref)),
    send(BM, report, status,
         'Found %d references to %s', Count, Word),
    send(BM, open).

add_lsp_reference(BM, Ref) :-
    #{range: Range, uri:URI} :< Ref,
    uri_file_name(URI, File),
    send(BM, lsp_add(File, Range)).

%   <-dabbrev_candidates
%
%   Get candidates for dynamic  abbreviations.   The  `user0`  target is
%   tried first. After that we  try   backward  search  and then forward
%   search in the buffer and than `user1`, `user2` and `user3`.

dabbrev_candidates(M, user0:name, Target:name, Completions:chain) :<-
    "Get additional candidates from the LSP server"::
    get(M, text_buffer, TB),
    get(TB, attribute, lsp_tracking, URI),
    get(M, lsp_client, complete, LSP),
    get(M, caret, Caret),
    get(TB, line_number, Caret, Line0),
    Line is Line0-1,
    get(TB, lsp_column, Caret, Char),
    get(LSP, call,
        'textDocument/completion'(
            #{ textDocument: #{ uri: URI },
               position: #{line: Line, character: Char},
               context: #{triggerKind: 1}
             }),
        Reply),
    convlist(completion(Target), Reply.get(items, []), List),
    chain_list(Completions, List).

completion(Target, Dict, Completion) :-
    Completion = Dict.get(insertText),
    sub_string(Completion, 0, _, _, Target).


                /*******************************
                *         DIAGNOSTICS          *
                *******************************/

selected_fragment(M, Fragment:fragment) :->
    "User selected a fragment in the margin"::
    send(M, show_fragment_note, Fragment).

hover_fragment_icon(M, Fragment:fragment*, _Area:[area]) :->
    "User selected a fragment in the margin"::
    (   Fragment == @nil
    ->  ignore(send(M, send_hyper, note, hover_end))
    ;   send(M, send_hyper, note, explicitly_opened)
    ->  true
    ;   send(M, show_fragment_note, Fragment, @on)
    ).

show_fragment_note(M, Fragment:fragment, Hover:[bool]) :->
    "Show message associated with a fragment below the fragment"::
    (   send(Fragment, instance_of, emacs_lsp_diagnostic)
    ->  get(M, editor, E),
        ignore(send(M, send_hyper, note, destroy)),
        new(W, emacs_lsp_diagnostic_window(E, Fragment, Hover)),
        new(_, partof_hyper(M, W, note, mode)),
        send(W, open)
    ;   true
    ).

goto_error(M, Dir:direction={next,prev}) :->
    "Goto the next/prev LSP diagnostic"::
    get(M, caret, Caret),
    (   (   Dir == next
        ->  get(M, find_fragment,
                and(message(@arg1, instance_of, emacs_lsp_diagnostic),
                    @arg1?start > Caret),
                Next)
        ;   get(M, find_all_fragments,
                and(message(@arg1, instance_of, emacs_lsp_diagnostic),
                    @arg1?end   < Caret),
                All),
            get(All, tail, Next)
        )
    ->  get(Next, start, Start),
        get(Next, end, End),
        send(M, selection, End, Start, highlight)
    ;   send(M, report, status, "No further diagnostic messages")
    ).

goto_next_error(M) :->
    "Go to the next LSP diagnostic"::
    send(M, goto_error, next).

goto_prev_error(M) :->
    "Go to the previous LSP diagnostic"::
    send(M, goto_error, prev).

:- emacs_end_mode.

:- use_module(library(doc/objects)). % @br, etc.
:- use_module(library(hyper)).

:- pce_begin_class(emacs_lsp_diagnostic_window, dialog,
                   "Show LSP diagnostics in modal window").

variable(lsp_client, lsp_client*, get, "Source LSP client").

class_variable(text_width, int, 400).

initialise(W, Editor:editor, Fragment:emacs_lsp_diagnostic,
           Hover:[bool]) :->
    get(Fragment, start, Offset),
    get(Editor, image, TextImage),
    get(TextImage, character_position, Offset, point(X,Y)),
    get(TextImage, frame_position, point(OX,OY)),
    get(Editor, frame, Master),
    send_super(W, initialise, "LSP Feedback"),
    send(W, slot, lsp_client, Fragment?lsp_client),
    send(W, transient_for, Master),
    send(W, kind, popup),
    get(Fragment, icon, Icon),
    send(W, append, new(I, label(icon, image(Icon)))),
    get(W, class_variable_value, text_width, TW),
    send(W, append, new(G, dialog_group(message,group)), right),
    send(G, append, new(M, parbox(TW, left))),
    send(M, name, message),
    send_list([I,G], reference, point(0,0)),
    (   Hover == @on
    ->  true
    ;   send(W, fixes_buttons, Fragment),
        send(W, append, new(Done, button(done, message(W, destroy)))),
        send(W, keyboard_focus, Done)
    ),
    send(W, message, Fragment?message),
    new(_, partof_hyper(Fragment, W, dialog, fragment)),
    send(W?frame, position, point(OX+X, OY+Y+2)).

destroy(W) :->
    "Allow calling from a thread"::
    (   thread_self(Me),
        pce_thread(Me)
    ->  send_super(W, destroy)
    ;   in_pce_thread(send(W, destroy))
    ).

explicitly_opened(W) :->
    "User opened this using a click"::
    get(W, member, done, _Button).

hover_end(W) :->
    "Mouse left the icon"::
    (   send(W, explicitly_opened)
    ->  true
    ;   send(W, destroy)
    ).

message(W, Msg:string) :->
    "Update the message"::
    get(W, member, message, Group),
    get(Group, member, message, PB),
    object(Msg, string(Message)),
    split_string(Message, '\n', '', Lines),
    append_pars(Lines, PB).

append_pars([], _) =>
    true.
append_pars([Last], PB) =>
    send(PB, cdata, Last).
append_pars([H|T], PB) =>
    send(PB, cdata, H),
    send_list(PB, append, [@nbsp,@br]),
    append_pars(T, PB).

fixes_buttons(W, Fragment:emacs_lsp_diagnostic) :->
    "Add buttons for available fixes"::
    get(Fragment, fixes, Fixes),
    (   member(Fix, Fixes),
        append_fix_button(W, Fix),
        fail
    ;   true
    ).

append_fix_button(W, Fix) :-
    #{ arguments: _Args, title: Title } :< Fix,
    fix_icon(Fix.command, Icon),
    get(W, member, message, Group),
    send(Group, append,
         new(LBL, label(icon, image(Icon))),
         next_row),
    send(Group, append,
         new(B, button(Title, message(W, apply_change, Title))),
         right),
    send(LBL, width, 32),
    send(LBL, reference, point(0, B?reference?y)),
    send(B, alignment, left).

fix_icon("clangd.applyTweak", '64x64/lsp-apply-tweak.png') :- !.
fix_icon("clangd.applyFix",   '64x64/lsp-apply-fix.png')   :- !.
fix_icon(_,                   '64x64/lsp-apply-fix.png').

apply_change(W, TitleObj:string) :->
    "Apply a selected change"::
    get(W, get_hyper, fragment, fixes, Fixes),
    object(TitleObj, string(TitleAtom)),
    atom_string(TitleAtom, Title),
    (   member(Fix, Fixes),
        #{title:Title} :< Fix
    ->  true
    ),
    get(W, lsp_client, LSP),
    send(W, destroy),
    send(LSP, execute_command, Fix).

:- pce_end_class.


                /*******************************
                *             UTIL             *
                *******************************/

%!  for_sheet(+Sheet, :Action) is semidet.
%
%   Call call(Action, Name, Value) for each attribute in Sheet.

for_sheet(Sheet, Action) :-
    get(Sheet, '_arity', Count),
    for_sheet_loop(1, Count, Sheet, Action).

for_sheet_loop(I, Count, Sheet, Action) :-
    I =< Count,
    !,
    get(Sheet, '_arg', I, attribute(Name, Value)),
    once(call(Action, Name, Value)),
    I2 is I+1,
    for_sheet_loop(I2, Count, Sheet, Action).
for_sheet_loop(_I, _Count, _Sheet, _Action).
