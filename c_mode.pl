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

:- module(my_c_mode, [ lsp_start/1,             % +Options
                       lsp_stop/0
                     ]).
:- use_module(library(pce)).
:- use_module(library(process)).
:- use_module(library(json_rpc_client)).
:- use_module(library(json_rpc_server)).
:- use_module(library(uri)).
:- use_module(library(broadcast)).
:- use_module(library(debug)).
:- use_module(library(pp)).
:- use_module(library(apply)).
:- use_module(library(pce_util)).
:- use_module(library(lists)).
:- use_module(library(error)).
:- use_module(library(filesex)).
:- use_module(library(option)).

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
%:- debug(lsp(process(log))).
%:- set_prolog_flag(debug_message_context, [time,thread]).

:- dynamic
    lsp_connection/1.                           % Stream

:- initialization
    listen(pce_emacs(Event), lsp_event(Event)).

%!  lsp_start(+Options) is det.
%
%   Start the LSP server.

lsp_start(Options) :-
    findall(Flag, clangd_option(Flag, Options), Flags),
    process_create(path(clangd),
                   Flags,
                   [ stdin(pipe(In)),
                     stdout(pipe(Out))
                   ]),
    stream_pair(Stream, Out, In),
    asserta(lsp_connection(Stream)),
    json_full_duplex(Stream,
                     [ header(true)
                     ]).

clangd_option(Flag, Options) :-
    option(compile_commands_dir(Dir), Options),
    format(atom(Flag), '--compile-commands-dir=~w', [Dir]).
clangd_option(Flag, Options) :-
    (   option(log(Level), Options)
    ->  true
    ;   debugging(lsp(process(Level)))
    ->  true
    ;   Level = error
    ),
    must_be(oneof([error,info,verbose]), Level),
    format(atom(Flag), '--log=~w', [Level]).


%!  lsp_stop
%
%   Stop the LSP server.

lsp_stop :-
    retract(lsp_connection(Stream)),
    close(Stream).

%!  lsp_init(+Dir, -Result) is det.
%
%   Initialize the LSP server for Dir

lsp_init(Dir, Result) :-
    uri_file_name(URI, Dir),
    findall(TokType, style(lsp(TokType),_), TokTypes),
    lsp_call(initialize(
                 #{ capabilities:
                      #{ textDocument:
                           #{ semanticTokens:
                                #{ dynamicRegistration: false,
                                   requests:
                                     #{ full: true,
                                        range: false
                                      }
                                 },
                              tokenTypes: TokTypes,
                              tokenModifiers: []
                            }
                       },
                    rootUri: URI
                  }),
            Result),
    clean_capabilities,
    catch_with_backtrace(register_capabilities(Result.capabilities),
                         E,
                         print_message(error, E)).

:- dynamic
    token_type/2,
    token_modifier/2.

clean_capabilities :-
    retractall(token_type(_,_)),
    retractall(token_modifier(_,_)).

register_capabilities(Capabilities) :-
    register_token_types(Capabilities.semanticTokensProvider.legend).

register_token_types(Legend) :-
    forall(nth0(Id, Legend.tokenTypes, String),
           ( atom_string(TokenType, String),
             assertz(token_type(Id, TokenType)))),
    forall(nth0(Id, Legend.tokenModifiers, String),
           ( atom_string(TokenModifier, String),
             Mask is 1<<Id,
             assertz(token_modifier(Mask, TokenModifier)))).

:- det(token_modifiers/2).
token_modifiers(0, []) :-
    !.
token_modifiers(Mask, [H|T]) :-
    token_modifier(M, H),
    Mask /\ M =\= 0,
    !,
    Mask1 is Mask /\ \M,
    token_modifiers(Mask1, T).


%!  c_find_project(+File, -Root, -Options) is det.

c_find_project(_File, Root, [compile_commands_dir(CompileCommandsDir)]) :-
    exists_file('compile_commands.json'),
    !,
    absolute_file_name('.', CompileCommandsDir),
    file_directory_name(CompileCommandsDir, Root).
c_find_project(File, Root, [compile_commands_dir(CompileCommandsDir)]) :-
    file_directory_name(File, Dir),
    parent_directory(Dir, Parent),
    compile_commands_dir(Parent, CompileCommandsDir),
    !,
    Root = Parent.
c_find_project(File, Root, []) :-
    file_directory_name(File, Root).

parent_directory(Dir, Dir).
parent_directory(Dir, Parent) :-
    file_directory_name(Dir, Direct),
    Direct \== Dir,
    parent_directory(Direct, Parent).

compile_commands_dir(Dir, CompileCommandsDir) :-
    format(string(Pattern), '~w/build{,.*}', [Dir]),
    expand_file_name(Pattern, BuildDirs),
    member(BuildDir, BuildDirs),
    exists_directory(BuildDir),
    directory_file_path(BuildDir, 'compile_commands.json', CompileCommandsFile),
    exists_file(CompileCommandsFile),
    !,
    CompileCommandsDir = BuildDir.


%!  lsp_highlight(+TextBuffer)
%
%   Do LSP based highlighting. Asks  for   the  tokens and applies them.
%   This seems to work fairly well, even for big files.

lsp_highlight(TB) :-
    send(TB, report, progress, 'LSP highlighting'),
    get(TB, attribute, lsp_tracking, URI),
    get_time(LSPTime0),
    lsp_call('textDocument/semanticTokens/full'(
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
    send(TB, for_all_fragments, message(@arg1, free)),
    get_time(FragmentTime0),
    highlight_tokens(Result.data, TB, 0, 0, 0, 0, Count),
    get_time(FragmentTime1),
    FragmentTime is FragmentTime1 - FragmentTime0,
    send(TB, report, progress,
         'Created %d fragments in %.3f seconds', Count, FragmentTime),
    send(TB, report, done).

%!  highlight_tokens(+DeltaTokens, +Buffer, +StartLine, +StartPos,
%!                   +Offset, +Count0, -Count) is det.
%
%   @bug Offset inside the line is measured   in UTF-16 units by LSP. As
%   is, we use them as Unicode code points.

highlight_tokens([], _, _, _, _, C, C).
highlight_tokens([IL,IP,Len,Tid,Mid|More], TB, SL0, SP0, O0, C0, C) :-
    (   IL == 0
    ->  SL = SL0,
        SP is SP0+IP,
        Offset is O0+IP
    ;   SL is SL0+IL,
        SP = IP,
        get(TB, scan, O0, line, IL, start, SOL),
        Offset is SOL+IP
    ),
    token_type(Tid, TokenType),
    StyleClass = lsp(TokenType),
    (   style(StyleClass, _)
    ->  debug(lsp(token), '~p:~p[~p]@~p: ~p',
              [SL,SP,Len,Offset,TokenType]),
        style_name(StyleClass, StyleName),
        new(F, emacs_c_fragment(TB, Offset, Len, StyleName)),
        send(F, slot, modifiers, Mid),
        C1 is C0+1
    ;   C1 = C0
    ),
    highlight_tokens(More, TB, SL, SP, Offset, C1, C).


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
style(lsp(keyword),    [bold(true), colour(blue)]).
style(lsp(function),   [bold(true)]).
style(lsp(type),       [colour(navyblue), bold(true)]).
style(lsp(macro),      [colour(blue)]).
style(lsp(enumMember), [colour(magenta)]).
style(lsp(enum),       [colour(magenta), bold(true)]).

style(comment,         [colour(darkgreen)]).


                /*******************************
                *      SERVER CONNECTION       *
                *******************************/

%ensure_lsp_server(_) :- !, fail.
ensure_lsp_server(_, c) :-
    lsp_connection(_),
    !.
ensure_lsp_server(File, c) :-
    c_find_project(File, Root, ProjectOptions),
    debug(lsp(project),
          'Found project.  Root=~q, Options=~p',
          [Root, ProjectOptions]),
    lsp_start(ProjectOptions),
    lsp_init(Root, _Result).

lsp_notify(Message) :-
    lsp_connection(Stream),
    json_notify(Stream, Message,
                [ header(true)
                ]).

lsp_call(Message, Result) :-
    lsp_connection(Stream),
    json_call(Stream, Message, Result,
              [ header(true)
              ]).


                /*******************************
                *           CONNECT            *
                *******************************/

lsp_event(opened(Buffer)) :-
    get(Buffer, mode, Mode),
    get(Buffer, file, File),
    File \== @nil,
    get(File, path, Path),
    ensure_lsp_server(Path, Mode),
    uri_file_name(URI, Path),
    debug(lsp(file), 'Opened ~p', [URI]),
    get(Buffer, contents, string(Content)),
    send(Buffer, attribute, lsp_version, 1),
    send(Buffer, attribute, lsp_tracking, URI),
    send(Buffer, lsp_changes, @on),
    lsp_notify('textDocument/didOpen'(
                   #{textDocument:
                       #{ uri: URI,
                          languageId: "c",
                          version: 1,
                          text: Content
                        }
                    })).
lsp_event(closed(Buffer)) :-
    get(Buffer, file, File),
    File \== @nil,
    pp(closed(File)).
lsp_event(changed(Buffer)) :-
    get(Buffer, attribute, lsp_tracking, URI),
    get(Buffer, lsp_changes, Changes),
    get(Buffer, attribute, lsp_version, Version0),
    Version is Version0+1,
    send(Buffer, attribute, lsp_version, Version),
    (   Changes == @nil
    ->  get(Buffer, contents, string(Content)),
        JSONChanges = [ #{text: Content} ],
        send(Buffer, lsp_changes, @on)                % re-enable incremental
    ;   chain_list(Changes, ChangeList),
        maplist(to_json, ChangeList, JSONChanges)
    ),
    lsp_notify(
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
         }).

'textDocument/publishDiagnostics'(Data) :-
    (   debugging(lsp(diagnostics))
    ->  pp(Data)
    ;   true
    ).


                /*******************************
                *           FRAGMENT           *
                *******************************/

:- pce_begin_class(emacs_c_fragment, emacs_colour_fragment).

variable(modifiers,	int := 0, get, "LSP token type modifiers").

identify(F) :->
    "Identify LSP fragments"::
    get(F, style, StyleName),
    get(F, modifiers, Mask),
    token_modifiers(Mask, Modifiers),
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
		     [ find_definition = key('\\e.')
		     ]).

class_variable(auto_colourise_size_limit, int, 400000).
class_variable(idle_timeout,              num, 0.1).

setup_mode(M) :->
    "Setup LSP based C mode"::
    send_super(M, setup_mode),
    send(M, setup_styles),
    (   lsp_connection(_)
    ->  true
    ;   get(M, text_buffer, Buffer),
        ignore(lsp_event(opened(Buffer))),
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
    (   get(TB, attribute, lsp_tracking, _URI)
    ->  lsp_highlight(TB)
    ;   send_super(M, colourise_buffer)
    ),
    send(TB, for_all_comments,
         create(emacs_c_fragment, TB,
                @arg1, @arg2 - @arg1, comment)).

find_definition(M) :->
    "LSP based find definition"::
    get(M, text_buffer, TB),
    get(TB, attribute, lsp_tracking, URI),
    get(M, caret, Caret),
    get(TB, line_number, Caret, Line1),
    Line is Line1 - 1,
    get(TB, lsp_column, Caret, Col),
    lsp_call('textDocument/definition'(
                 #{ textDocument:
                      #{ uri: URI
                       },
                    position:
                      #{ line: Line,
                         character: Col
                       }
                  }),
             Result),
    send(M, lsp_edit, Result).

lsp_edit(M, Location:prolog) :->
    "Edit a location returned by the LSP server"::
    (   is_list(Location)
    ->  lsp_select_hit(Location, Hit)
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

lsp_select_hit([Hit], Hit) :-
    !.
lsp_select_hit(Hits, _) :-
    debug(lsp(location), 'Got these hits: ~p', [Hits]),
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

:- emacs_end_mode.
