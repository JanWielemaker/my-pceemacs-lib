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

:- module(emacs_vale_extension,
          []).
:- use_module(library(pce)).

/** <module> Vale extension

This module provides methods for   integrating `vale` through `vale-ls`.
`vale-ls` is a rather  limited  LSP   implementation.  It  replies using
diagnostics on didOpen() and didSave().  Both   methods  are required to
send the full content of the file, but   the  actual analysis is done by
the `vale` CLI program reading from the   file. This implies that to get
diagnostics, we need:

  1. Save the file in the designated URI
  2. Call textDocument/didSave() providing the (same) full text.
*/

:- emacs_extend_mode(language, []).

vale_check(M) :->
    "Run spell checking using vale-ls"::
    (   get(M, text_buffer, TB),
        get(TB, attribute, lsp_tracking, URI),
        get(M, lsp_client, diagnostics, LSP),
        pp([M,TB,LSP]),
        get(LSP, initialized, @on)
    ->  send(M, report, status, 'Checking ...'),
        get(TB, contents, string(Content)),
        string_length(Content, Len),
        format("~p: sending ~D characters~n", [M, Len]),
        uri_file_name(URI, File),
        (   fail
        ->  format(string(Cmd), 'touch "~w"', [File]),
            shell(Cmd)
        ;   setup_call_cleanup(
                open(File, write, Out),
                format(Out, '~s', [Content]),
                close(Out))
        ),
        send(LSP, notify,
             'textDocument/didSave'(
                 #{ textDocument:
                      #{ uri: URI
                       },
                    text: Content
                  }))
    ;   true
    ).

:- emacs_end_mode.
