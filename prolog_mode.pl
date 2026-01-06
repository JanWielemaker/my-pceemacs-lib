/*  Author:        Jan Wielemaker
    E-mail:        jan@swi-prolog.org
    WWW:           http://www.swi-prolog.org
    Copyright (c)  2026, SWI-Prolog Solutions b.v.
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

:- module(my_prolog_mode, []).
:- use_module(library(pce)).
:- use_module(library(prolog_xref)).

:- use_module(autocomplete).
:- use_module(lsp_diagnostics).
:- use_module(vale).


                /*******************************
                *            THEME             *
                *******************************/

:- multifile
    emacs_prolog_mode:style/2.

emacs_prolog_mode:def_style(Class, Attributes) :-
    style(Class, Attributes).

style(Diagnostic,      Properties) :-
    lsp_diagnostic_style(Diagnostic, Properties).

:- multifile
    emacs_prolog_mode:lsp_configuration/2.


                /*******************************
                *             MODE             *
                *******************************/
:- emacs_extend_mode(prolog,
		     [ show_syntax = key('\\C-\\'),
		       autocomplete = key('\\C-c\\C-p')
		     ]).

class_variable(lsp_roles, sheet*,
               sheet(attribute(diagnostics, 'vale-ls'))).

setup_mode(M) :->
	"Setup Prolog and Vale"::
	send_super(M, setup_mode),
	send(M, setup_prolog_mode),
	ignore(send(M, lsp_setup_highlight)).

show_syntax(M) :->
	"Show syntactical category at point"::
	get(M, caret, Caret),
	get(M, scan_syntax, 0, Caret, tuple(Syntax, Start)),
	send(M, report, inform,
	     'Syntax at %d is %s, started at %d', Caret, Syntax, Start).


		 /*******************************
		 *	 SYNTAX CHECKING	*
		 *******************************/

check_region(M) :->
	"Check syntax in region"::
	get(M, region, tuple(Start, End)),
	get(M, scan, Start, line, 0, start, SOL),
	get(M, scan, End, line, 0, start, EOL),
	check_region(M, SOL, EOL, Checked),
	send(M, report, status, 'Checked %d clauses', Checked).

check_region(_, SOL, EOL, 0) :-
	SOL >= EOL, !.
check_region(M, SOL, EOL, N) :-
	get(M, check_clause, SOL, EOC),
	check_region(M, EOC, EOL, NN),
	N is NN + 1.


		 /*******************************
		 *	 AUTO-COMPLETION	*
		 *******************************/

completions(M, _SOW:int, Prefix:name, Completions:chain) :<-
	"Autocomplete predicate"::
	get(M, text_buffer, TB),
	findall(DI, completion(TB, Prefix, DI), List),
	chain_list(Completions, List),
	send(Completions, sort).

completion(_TB, Prefix, DI) :-
	predicate_property(system:Head, built_in),
	functor(Head, Name, Arity),
	sub_atom(Name, 0, _, _, Prefix),
	new(DI, dict_item(Name, string('%s/%d', Name, Arity))),
	send(DI, style, built_in).
completion(TB, Prefix, DI) :-
	xref_defined(TB, Callable, How),
	functor(Callable, Name, Arity),
	sub_atom(Name, 0, _, _, Prefix),
	new(DI, dict_item(Name, string('%s/%d', Name, Arity))),
	functor(How, Style, _),
	send(DI, style, Style).
completion(_TB, Prefix, DI) :-
	'$in_library'(Name, Arity, _Path),
	sub_atom(Name, 0, _, _, Prefix),
	new(DI, dict_item(Name, string('%s/%d', Name, Arity))),
	send(DI, style, autoload).

setup_completion_styles(M, F:autocomplete_browser) :->
	"Setup the styles for candidate predicates"::
	get(F, browser, Browser),
	get(M, styles, Sheet),
	(   copy_style(Name, Class),
	    emacs_prolog_mode:style(goal(Class,_), StyleName, _),
	    get(Sheet, value, StyleName, Style),
	    send(Browser, style, Name, Style),
	    fail
	;   true
	).

copy_style(built_in,	 built_in).
copy_style(autoload,	 autoload).
copy_style(local,	 local(_)).
copy_style(imported,	 imported(_)).
copy_style(dynamic,	 dynamic(_)).
copy_style(thread_local, thread_local(_)).

insert_autocompletion(M, Text:char_array) :->
	send_super(M, insert_autocompletion, Text),
	send(M, mark_variable, @(on)).

:- emacs_end_mode.
