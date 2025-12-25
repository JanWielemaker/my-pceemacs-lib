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

:- initialization
    listen(pce_emacs(Event), lsp_event(Event)).

:- meta_predicate
    for_sheet(+, 2).

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
    lsp_token_type(LSP, Tid, TokenType),
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

style(Diagnostic,      Properties) :-
    lsp_diagnostic_style(Diagnostic, Properties).


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
              document_open(URI, Content)).

document_open(URI, Content, _Id, LSP) :-
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
              document_close(URI)).

document_close(URI, _Id, LSP) :-
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
                *           FRAGMENT           *
                *******************************/

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
                       find_references = key('\\e?')
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


:- emacs_end_mode.


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
