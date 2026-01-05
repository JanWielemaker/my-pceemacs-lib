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

Unfortunately,  `vale`  is  rather  slow  and   can  only  analyse  full
documents. To implement quick  local  checking,   we  must  associate  a
temporary file and use that with didOpen(), didSave(), etc.
*/

:- emacs_extend_mode(language, []).

%   ->vale_check_region(Start, View)
%
%   Check the region Start..Start+View, rounded   outwards to lines. The
%   defaults are the currently visible area.

vale_check_region(M, Start:start=['0..'], View:view=['0..']) :->
    get(M, text_buffer, TB),
    get(M, lsp_client, diagnostics, LSP),
    get(M, image, TI),
    (   Start == @default
    ->  get(TI, start, StartPos)
    ;   StartPos = Start
    ),
    (   View == @default
    ->  get(TI, view, ViewLen)
    ;   ViewLen = View
    ),
    get(TB, scan, StartPos,         line, 0, start, SOL),
    get(TB, scan, StartPos+ViewLen, line, 0, end,   EOL),
    get(TB, region_lsp, LSP, Region),
    send(Region, range, SOL, EOL),
    send(Region, did_save).

vale_check(M) :->
    "Run spell checking using vale-ls"::
    (   get(M, text_buffer, TB),
        get(TB, attribute, lsp_tracking, URI),
        get(M, lsp_client, diagnostics, LSP),
        get(LSP, initialized, @on)
    ->  send(M, report, status, 'Checking ...'),
        get(TB, contents, string(Content)),
        send(TB, do_save, TB?file, 0),
        send(LSP, notify,
             'textDocument/didSave'(
                 #{ textDocument:
                      #{ uri: URI
                       },
                    text: Content
                  }))
    ;   send(M, report, warning, 'Cannot spell-check using vale-ls')
    ).

:- emacs_end_mode.
