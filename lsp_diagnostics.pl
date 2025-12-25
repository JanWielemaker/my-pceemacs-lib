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

:- module(lsp_diagnostics,
          [ lsp_diagnostic_style/2,  % ?StyleName, ?StyleProperties
            lsp_severity_type/3      % ?LSPLevel, ?LSPName, ?FragmentStyle
          ]).
:- use_module(library(pce)).
:- use_module(library(doc/objects)). % @br, etc.
:- use_module(library(hyper)).
:- use_module(library(apply)).
:- use_module(library(debug)).
:- use_module(library(lists)).
:- use_module(library(pce_util)).

/** <module> Handle LSP disagnostic messages

This  module  provides  the  infrastructucture  to  deal  with  the  LSP
initiated ``textDocument/publishDiagnostics()`` method. It extends class
`emacs_buffer` to create `emacs_lsp_diagnostic`  fragments, hovering and
selecting fragments and initiating "fix available" edits.
*/

%!  lsp_severity_type(?LSPLevel, ?LSPName, ?FragmentStyle).

lsp_severity_type(1, error,   lsp_diag_error).
lsp_severity_type(2, warning, lsp_diag_warning).
lsp_severity_type(3, info,    lsp_diag_info).
lsp_severity_type(4, hint,    lsp_diag_hint).

:- det(style_pce_severity/3).
style_pce_severity(lsp_diag_error,   error,   'Error').
style_pce_severity(lsp_diag_warning, warning, 'Warning').
style_pce_severity(lsp_diag_info,    status,  'Information').
style_pce_severity(lsp_diag_hint,    status,  'Hint').

%!  lsp_diagnostic_style(?StyleName, ?StyleProperties) is nondet.
%
%   Provide style name and properties for the LSP diagnostic fragments.

lsp_diagnostic_style(lsp_diag_error,   [icon(Icon), underline(red)]) :-
    lsp_icon(error, Icon).
lsp_diagnostic_style(lsp_diag_warning, [icon(Icon), underline(orange)]) :-
    lsp_icon(warning, Icon).
lsp_diagnostic_style(lsp_diag_info,    [icon(Icon), underline(yellow)]) :-
    lsp_icon(info, Icon).
lsp_diagnostic_style(lsp_diag_hint,    [icon(Icon), underline(navyblue)]) :-
    lsp_icon(hint, Icon).

lsp_icon(error,   '64x64/lsp-error.png').
lsp_icon(warning, '64x64/lsp-warning.png').
lsp_icon(info,    '64x64/lsp-information.png').
lsp_icon(hint,    '64x64/lsp-hint.png').


                /*******************************
                *     EXTEND LANGUAGE MODE     *
                *******************************/

:- emacs_extend_mode(language,
                     [ goto_next_error = key('\\egn'),
                       goto_prev_error = key('\\egp')
                     ]).

:- pce_group(diagnostic).

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

goto_lsp_diagnostic(M, Dir:direction={next,prev}) :->
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
    send(M, goto_lsp_diagnostic, next).

goto_next_error(M) :->
    "Go to the previous LSP diagnostic"::
    send(M, goto_lsp_diagnostic, prev).

:- emacs_end_mode.


                /*******************************
                *     EXTEND EMACS BUFFER      *
                *******************************/

:- pce_extend_class(emacs_buffer).

lsp_publish_diagnostics(Buffer, LSP:lsp_client, Diagnostics:prolog) :->
    "Create fragments from diagnostics"::
    send(Buffer, for_all_fragments,
         if(message(@arg1, instance_of, emacs_lsp_diagnostic),
            message(@arg1, free))),
    State = counts(0,0,0,0),
    maplist(show_diagnostic(Buffer, LSP, State), Diagnostics),
    report_diagnostic_counts(State, Buffer),
    debug(lsp(diagnostics), 'Counts: ~p', [State]).

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


:- pce_end_class.


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

:- pce_end_class.


                /*******************************
                *            WINDOW            *
                *******************************/

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
