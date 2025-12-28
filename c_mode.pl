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
:- use_module(library(uri)).
:- use_module(library(broadcast)).
:- use_module(library(debug)).
:- use_module(library(apply)).
:- use_module(library(pce_util)).
:- use_module(library(lists)).

:- use_module(lsp_client).
:- use_module(lsp_highlight).
:- use_module(lsp_diagnostics).
:- use_module(lsp_symbol_item).

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

:- multifile
    emacs_c_mode:style/2.

emacs_c_mode:def_style(Class, Attributes) :-
    style(Class, Attributes).

style(lsp(comment),    [colour(orange)]).              % Inactive code
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

style(Diagnostic,      Properties) :-
    lsp_diagnostic_style(Diagnostic, Properties).


                /*******************************
                *            C MODE            *
                *******************************/

:- emacs_extend_mode(c,
		     [ find_definition = key('\\e.'),
                       find_references = key('\\e?')
		     ]).

class_variable(auto_colourise_size_limit, int, 400000).
class_variable(idle_timeout,              num, 0.3).
class_variable(lsp_roles,		  sheet*,
               sheet(attribute(highlight, clangd),
                     attribute(symbol,    clangd),
                     attribute(complete,  clangd))).

setup_mode(M) :->
    "Setup LSP based C mode"::
    send_super(M, setup_mode),
    (   get(M, attribute, lsp_clients, _)
    ->  send(M, setup_styles)
    ;   get(M, text_buffer, Buffer),
        broadcast(pce_emacs(opened(Buffer))),
        send(M, setup_styles),
        % needs to be called in next event cycle
        new(T, timer(0.1,
                     and(message(M, colourise_buffer),
                         message(@receiver, free)))),
        send(T, start, once),
        send(T, lock_object, @on)
    ).

%   ->colourise_buffer_no_lsp
%
%   Perform basic C syntax highlighting.  This deals with comments
%   and C keyboards

colourise_buffer_no_lsp(M) :->
    "Basic C syntax highlighting"::
    get(M, text_buffer, TB),
    send(TB, for_all_syntax,
         message(M, highlight, @arg1, @arg2 - @arg1, @arg3)).

highlight(M, From:int, Len:int, Style:name) :->
    "Add a highlight fragment"::
    get(M, text_buffer, TB),
    adjust_style(Style, M, TB, From, Len, TheStyle),
    new(_, emacs_lsp_fragment(TB, From, Len, TheStyle)).

adjust_style(keyword, M, TB, From, Len, Style) =>
    get(TB, contents, From, Len, string(KeywordS)),
    atom_string(Keyword, KeywordS),
    get(M, keyword_type, Keyword, Style).
adjust_style(Style0, _M, _TB, _From, _Len, Style) =>
    Style = Style0.


                /*******************************
                *      CROSS-REFERENCING       *
                *******************************/

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

:- emacs_end_mode.
