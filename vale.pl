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

:- use_module(library(debug)).
:- use_module(library(lists)).
:- use_module(library(uri)).
:- use_module(library(emacs/lsp_client)).
:- use_module(library(emacs/lsp_highlight)).
:- use_module(library(emacs/lsp_diagnostics)).

:- multifile
    lsp_registry:lsp_server/2,
    lsp_registry:lsp_argument/3.

%   LSP servers for prose.  vale-ls is used if the Prolog flag `vale`
%   is `true`.

lsp_registry:lsp_server('vale-ls',
                        #{ executable: path('vale-ls'),
                           modes:      [markdown,latex,html,c,prolog],
                           roles:      [spelling],
                           change:     1,             % only full changes
                           spelling:
                             #{ codes: ['Vale.Spelling', 'Vale.Terms' ],
                                dictionary: '~/.local/share/vale/styles/config/vocabularies/Project/accept.txt'
                              }
                         }) :-
    current_prolog_flag(vale, true).
/*
lsp_registry:lsp_server('ltex-ls',
                        #{ executable: path('ltex-ls'),
                           modes:      [markdown,latex,html]
                         }).
*/

lsp_registry:lsp_argument('ltex-ls', _, Arg) :-
    debugging(lsp(log('ltex-ls', File))),
    format(atom(Arg), '--log-file=~w', [File]).

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
    get(M, lsp_client, spelling, LSP),
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
        get(M, lsp_client, spelling, LSP),
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


                /*******************************
                *        REGION CHECKING       *
                *******************************/

% vale-ls can only check complete files.  To check part of a buffer, the
% region is saved to a temporary file and checked.  The diagnostics it
% gives are moved to the region by lsp_client (see
% lsp_set_document_region/3).

:- pce_extend_class(emacs_buffer).

region_lsp(TB, LSP:lsp_client, Region:lsp_region_fragment) :<-
    "Establish an LSP for a region"::
    (   get(TB, attribute, att_region_lsp, Region)
    ->  true
    ;   new(Region, lsp_region_fragment(TB, LSP)),
        send(TB, attribute, att_region_lsp, Region)
    ).

:- pce_end_class.

:- pce_begin_class(lsp_region_fragment, fragment,
                   "Used to mark region for an LSP to work on").

variable(uri,	     name,       get, "Region URI").
variable(lsp_client, lsp_client, get, "LSP we are connected to").
variable(file,	     file,       get, "(Tmp) file connected").

initialise(Region, TB:emacs_buffer, LSP:lsp_client) :->
    send_super(Region, initialise, TB, 0, 0, lsp_region),
    get(TB, attribute, lsp_tracking, DocumentURI),
    file_name_extension(_, Ext, DocumentURI),
    tmp_file_stream(TmpFile, Stream,
                    [ encoding(utf8),
                      extension(Ext)
                    ]),
    close(Stream),
    uri_file_name(RegionURI, TmpFile),
    send(Region, slot, uri,        RegionURI),
    send(Region, slot, lsp_client, LSP),
    send(Region, slot, file,       TmpFile),
    get(TB, mode, Mode),
    send(LSP, notify,
         'textDocument/didOpen'(
             #{textDocument:
                 #{ uri: RegionURI,
                    languageId: Mode,
                    version: 1,
                    text: ""
                  }
              })),
    debug(vale(region), 'Established region using ~q', [TmpFile]).

unlink(Region) :->
    "Cleanup registration"::
    get(Region, text_buffer, TB),
    ignore(send(TB, delete_attribute, att_region_lsp)),
    get(Region, uri, RegionURI),
    lsp_delete_document_region(RegionURI),
    get(Region?file, absolute_path, TmpFile),
    catch(delete_file(TmpFile), _, true),
    send_super(Region, unlink).

range(Region, Start:start=int, End:end=int) :->
    "Set extends"::
    send(Region, start, Start, @off),
    send(Region, end, End).

did_save(Region) :->
    "Save content to file and notify LSP using didSave()"::
    get(Region, text_buffer, TB),
    get(TB, attribute, lsp_tracking, DocumentURI),
    get(Region, string, string(Text)),
    get(Region, start, Start),
    get(Region, end, End),
    send(TB, do_save, Region?file, Start, End),
    get(Region, uri, RegionURI),
    debug(vale(region), 'Using didSave to check ~d..~d',
          [Start, End]),
    lsp_set_document_region(RegionURI, DocumentURI, Region),
    send(Region?lsp_client, notify,
         'textDocument/didSave'(
             #{ textDocument:
                  #{ uri: RegionURI
                   },
                text: Text
              })).

:- pce_end_class.


                /*******************************
                *           SPELLING           *
                *******************************/

:- dynamic
    session_dictionary/1.

:- multifile
    lsp_diagnostics:suppress_diagnostic/5,
    lsp_diagnostics:diagnostic_buttons/2.

lsp_diagnostics:suppress_diagnostic(Buffer, LSP, StartOffset, Length, Diagnostic) :-
    get(LSP, config, Config),
    SpellingCodes = Config.get(spelling).get(codes),
    atom_string(SpellingCode, Diagnostic.get(code)),
    memberchk(SpellingCode, SpellingCodes),
    get(Buffer, contents, StartOffset, Length, string(String)),
    atom_string(Word, String),
    session_dictionary(Word).

lsp_diagnostics:diagnostic_buttons(W, Fragment) :-
    send(W, add_dictionary_buttons, Fragment).

:- pce_extend_class(emacs_lsp_diagnostic_window).

% Deal   with   suppressing   and   dictionary   additions.   Some   LSP
% implementation do this for you,  some  don't.   In  that  case the LSP
% registration should contain a key `spelling` with values `code` set to
% the diagnostic code emitted  for   spelling  errors  and `dictionary`,
% pointing at a file that is used for the user dictionary.

%   ->add_dictionary_buttons(+Fragment)
%
%   Added _accept_ and _dictionary_  buttons  if   this  is  a  spelling
%   correction action and the LSP registry asks us to.

add_dictionary_buttons(W, Fragment:emacs_lsp_diagnostic) :->
    "Add buttons for accept and dictionary"::
    get(Fragment, code, Code),
    get(Fragment, lsp_client, LSP),
    get(LSP, config, Dict),
    memberchk(Code, Dict.get(spelling).get(codes)),
    get(Fragment?string, value, Word),
    send(W, action_button, image('ide/lsp/dictionary.svg'),
         'Accept (session)', message(W, accept, Word, session)),
    send(W, action_button, image('ide/lsp/dictionary.svg'),
         add_to_dictionary, message(W, accept, Word, dictionary)).

accept(W, Word:name, Scope:{session,dictionary}) :->
    "Accept a word marked as spelling error"::
    get(W, hypered, fragment, Fragment),
    (   Scope == session
    ->  asserta(session_dictionary(Word))
    ;   get(Fragment, lsp_client, LSP),
        get(LSP, config, Dict),
        FileSpec = Dict.get(spelling).get(dictionary),
        dictionary_file(FileSpec, File),
        setup_call_cleanup(
            open(File, append, Out,
                 [ encoding(utf8)
                 ]),
            format(Out, '~w~n', [Word]),
            close(Out))
    ),
    same_diagnostics(Fragment, All),
    forall(member(F, All),
           send(F, free)).

dictionary_file(FileSpec, File) :-
    atomic(FileSpec),
    expand_file_name(FileSpec, [File]).
dictionary_file(FileSpec, File) :-
    absolute_file_name(FileSpec, File,
                       [ access(write)
                       ]).

:- pce_end_class.
