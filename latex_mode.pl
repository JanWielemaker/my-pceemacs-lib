:- module(my_latex_mode,
          []).
:- use_module(library(pce)).
:- use_module(library(debug)).

:- use_module(lsp_diagnostics).

:- debug(lsp(_)).
:- debug(json_rpc(_)).

:- emacs_extend_mode(latex, []).

class_variable(auto_colourise_size_limit, int, 400000).
class_variable(idle_timeout,              num, 0.3).
class_variable(lsp_roles,		  sheet*,
               sheet(attribute(diagnostics, 'ltex-ls'))).

setup_mode(M) :->
     "Setup LSP based LaTeX mode"::
    send_super(M, setup_mode),
    ignore(send(M, lsp_setup)).

:- emacs_end_mode.

