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

:- module(lsp_highlight, []).
:- use_module(library(pce)).
:- use_module(library(apply)).
:- use_module(library(debug)).

:- use_module(lsp_client).

/** <module> Generic LSP based highlighting
*/

:- pce_extend_class(emacs_buffer).

auto_colourise(TB) :->
    "Run mode ->auto_colourise_buffer on associated mode"::
    (   get(TB?editors, head, Editor)
    ->  send(Editor?mode, auto_colourise_buffer)
    ;   true
    ).

%   ->lsp_highlight(+LSP)
%
%   Do LSP based highlighting. Asks  for   the  tokens and applies them.

lsp_highlight(TB, LSP:lsp_client) :->
    "Implement LSP based semantic highlighting"::
    get(LSP, initialized, @on),
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
    get(TB, mode, Mode),
    lsp_token_type(LSP, Tid, TokenType),
    StyleClass = lsp(TokenType),
    (   mode_style(Mode, StyleClass, _)
    ->  debug(lsp(token), '~p:~p[~p]@~p: ~p',
              [SL,SP,Len,Offset,TokenType]),
        style_name(StyleClass, StyleName),
        new(F, emacs_lsp_fragment(TB, Offset, Len, StyleName)),
        send(F, slot, lsp_client, LSP),
        send(F, slot, modifiers, Mid),
        C1 is C0+1
    ;   C1 = C0
    ),
    highlight_tokens(More, LSP, TB, SL, SP, Offset, C1, C).

:- pce_end_class.


                /*******************************
                *       MODE EXTENSIONS        *
                *******************************/

:- emacs_extend_mode(language, []).

class_variable(lsp_margin_width, int, 22,
               "Width for diagnostic icon margin").

:- pce_group(diagnostic).

lsp_enable_margin(M, Enable:[bool]) :->
    "Enable the diagnostic margin"::
    (   Enable == @off
    ->  send(M, margin_width, 0)
    ;   (   Enable == @on
        ;   get(M, find_fragment,
                message(@arg1, instance_of, emacs_lsp_diagnostic), _)
        )
    ->  get(M, class_variable_value, lsp_margin_width, Width),
        send(M, margin_width, Width)
    ).


%   ->lsp_setup_highlight()
%
%   Prepare the editor for LSP based highligting.  This serves two
%   roles:
%
%     - Possibly connect to LSP servers
%     - Initialise the style mapping for highlighting tokens.

lsp_setup_highlight(M) :->
    "Prepare using an LSP on this mode"::
    (   styled_role(Role),
        get(M, lsp_client, Role, _)
    ->  send(M, lsp_setup_styles)
    ;   send(M, lsp_setup),
        styled_role(Role),
        get(M, lsp_client, Role, _),
        send(M, lsp_setup_styles),
        % needs to be called in next event cycle
        new(T, timer(0.1,
                     and(message(M, colourise_buffer),
                         message(@receiver, free)))),
        send(T, start, once),
        send(T, lock_object, @on)
    ).

styled_role(highlight).
styled_role(diagnostics).

lsp_setup_styles(M) :->
    "Initialize the editor style sheet"::
    get(M, editor, E),
    (   get(E, attribute, lsp_styles_assigned, @on)
    ->  true
    ;   get(M, name, ModeName),
        forall(style(ModeName, _Class, Name, Style),
               send(E, style, Name, Style)),
        send(E, attribute, lsp_styles_assigned, @on)
    ),
    send(M, lsp_enable_margin).

colourise_buffer(M) :->
    "Use LSP based highlighting"::
    get(M, text_buffer, TB),
    (   get(M, lsp_client, highlight, LSP),
        (   get(LSP, initialized, @on)
        ->  send(TB, lsp_highlight, LSP)
        ;   send(LSP, register_pending,
                 message(M, colourise_buffer))
        )
    ->  send(M, update_bookmarks)
    ;   send_super(M, colourise_buffer)
    ),
    (   send(M, has_send_method, colourise_buffer_no_lsp)
    ->  send(M, colourise_buffer_no_lsp)
    ;   true
    ).

:- emacs_end_mode.


%!  style(+Mode, ?Class, -Name, -Style) is nondet.
%
%   Define the styles.

style(Mode, Class, Name, Style) :-
    mode_style(Mode, Class, Attributes),
    style_name(Class, Name),
    maplist(style_attribute, Attributes, PceArgs),
    (   PceArgs == []
    ->  Style = @default
    ;   Style =.. [style|PceArgs]
    ).

style_attribute(Attr, Name := Value) :-
    Attr =.. [Name,Value].

%!  mode_style(+Mode, +StyleClass, -Attributes) is semidet.
%!  mode_style(+Mode, -StyleClass, -Attributes) is nondet.

mode_style(Mode, StyleClass, Attributes) :-
    nonvar(StyleClass),
    !,
    lsp_mode_module(Mode, Module),
    (   Module:style(StyleClass, Attributes)
    ->  true
    ;   Module:def_style(StyleClass, Attributes)
    ).
mode_style(Mode, StyleClass, Attributes) :-
    atomic_list_concat([emacs_, Mode, '_mode'], Module),
    (   Module:style(StyleClass, Attributes)
    ;   Module:def_style(StyleClass, Attributes),
        \+ ( Module:style(UserClass, _),
             UserClass =@= StyleClass )
    ).

%!  style_name(?Term, ?StyleName:atom) is det.
%
%   Map between the term representation for styles and the (atom) name
%   we need to use for the xpce style name.

:- table style_name/2.
style_name(Class, StyleName) :-
    nonvar(Class),
    !,
    copy_term(Class, Copy),
    numbervars(Copy, 0, _, [singletons(true)]),
    term_string(Copy, S, [numbervars(true)]),
    atom_string(StyleName, S).
style_name(Class, StyleName) :-
    term_string(Class, StyleName).


                /*******************************
                *           FRAGMENT           *
                *******************************/

:- pce_begin_class(emacs_lsp_fragment, emacs_colour_fragment,
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
    style_name(Style, StyleName),
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
