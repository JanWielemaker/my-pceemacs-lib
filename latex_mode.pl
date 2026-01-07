:- module(my_latex_mode,
          []).
:- use_module(library(pce)).
:- use_module(library(debug)).

:- use_module(lsp_diagnostics).
:- use_module(lsp_highlight).
:- use_module(vale).

%:- debug(lsp(workspace)).
%:- debug(lsp(_)).
%:- debug(json_rpc(_)).

                /*******************************
                *            THEME             *
                *******************************/

:- multifile
    emacs_latex_mode:style/2.

emacs_latex_mode:def_style(Class, Attributes) :-
    style(Class, Attributes).

style(Diagnostic,      Properties) :-
    lsp_diagnostic_style(Diagnostic, Properties).

:- multifile
    emacs_latex_mode:lsp_configuration/2.

emacs_latex_mode:lsp_configuration(Item, Config) :-
    #{scopeUri: _URI, section: "ltex"} :< Item,
    Config = #{ latex:
                  #{ environments:
                       #{ code: "ignore"
                        },
                     commands:
                       #{ '\\const': "ignore",
                          '\\program': "ignore",
                          '\\file': "ignore",
                          '\\secref': "ignore",
                          '\\Secref': "ignore",
                          '\\figref': "ignore",
                          '\\Figref': "ignore",
                          '\\cfunction': "ignore",
                          '\\predicate': "ignore",
                          '\\cmacro': "ignore",
                          '\\ctype': "ignore",
                          '\\arg': "ignore"
                        }
                   }
              }.


                /*******************************
                *             MODE             *
                *******************************/

:- emacs_extend_mode(latex,
                     [ vale_check = key('\\C-l')
                     ]).

class_variable(auto_colourise_size_limit, int, 400000).
class_variable(idle_timeout,              num, 0.3).
class_variable(lsp_roles,		  sheet*,
               sheet(attribute(spelling, 'vale-ls'))).

colourise_buffer(M) :->
    "Do spell checking"::
    send_super(M, colourise_buffer),
    send(M, vale_check_region).

setup_mode(M) :->
     "Setup LSP based LaTeX mode"::
    send_super(M, setup_mode),
    ignore(send(M, lsp_setup_highlight)).

:- emacs_end_mode.

