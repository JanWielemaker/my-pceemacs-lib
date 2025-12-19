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

:- module(lsp_registry,
          [ lsp_server/3,               % ?Id, -Config
            project_root/3              % +File, -Root, +Options
          ]).
:- autoload(library(option), [option/3]).
:- autoload(library(process), [process_create/3]).
:- use_module(library(debug), [debugging/1]).
:- autoload(library(error), [must_be/2]).
:- autoload(library(filesex), [directory_file_path/3]).
:- autoload(library(pairs), [map_list_to_pairs/3]).

:- multifile
    lsp_server/2,                       % ?LSPId, -Config
    lsp_argument/3.                     % ?LSPId, +Root, -Arg

/** <module> Reason about available LSP servers
*/

%!  lsp_server(?Id, +Root, -Config) is nondet.
%
%   True when Id is the identifier for a n LSP server to be started in a
%   workspace at Root with given configuration Config.

lsp_server(clangd, Root,
           #{ executable: path(clangd),
              arguments:  Argv,
              modes:      [c,cpp]
            }) :-
    findall(Arg, lsp_argument(clangd, Root, Arg), Argv).
lsp_server('ltex-ls', Root,
           #{ executable: path('ltex-ls'),
              arguments:  Argv,
              modes:      [markdown,latex,html]
            }) :-
    findall(Arg, lsp_argument('ltex-ls', Root, Arg), Argv).

%!  lsp_argument(+Id, +Root, -Arg) is nondet.
%
%   Provide additional arguments for LSP server Id to run in a workspace
%   rooted by Root.

lsp_argument(clangd, Root, Arg) :-
    compile_commands_file(Root, CompileCommandsFile),
    file_directory_name(CompileCommandsFile, Dir),
    format(atom(Arg), '--compile-commands-dir=~w', [Dir]).
lsp_argument(clangd, _, Arg) :-
    (   debugging(lsp(log(clangd, Level)))
    ->  must_be(oneof([error,info,verbose]), Level)
    ;   Level = error
    ),
    format(atom(Arg), '--log=~w', [Level]).
lsp_argument('ltex-ls', _, Arg) :-
    debugging(lsp(log('ltex-ls', File))),
    format(atom(Arg), '--log-file=~w', [File]).


                /*******************************
                *           PROJECT            *
                *******************************/

%!  project_root(+File, -Root, +Options) is det.
%
%   Find the project root given a specific file.

project_root(File, Root, Options) :-
    option(from(Source), Options, _),
    project_root(Source, File, Root, Options).

%!  project_root(+From, +File, -Root, +Options)
%
%   Find the project root using some technique.

project_root(git, File, Root, _Options) :-
    (   dir_from_git(File, '--show-superproject-working-tree', Root0)
    ->  Root = Root0
    ;   dir_from_git(File, '--show-toplevel', Root)
    ).

dir_from_git(File, How, Root) :-
    file_directory_name(File, Dir),
    setup_call_cleanup(
        process_create(path(git),
                       [ '-C', Dir, 'rev-parse', How ],
                       [ stdout(pipe(Out)) ]),
        read_string(Out, _, Result),
        close(Out)),
    split_string(Result, "\n", "\n\r\t\s", [Line]),
    Line \== "",
    atom_string(Root, Line).

                /*******************************
                *        CMAKE SUPPORT         *
                *******************************/

%!  compile_commands_file(+Root, -File) is semidet.
%
%   True    when    File    is    the    absolute    file    path    for
%   'compile_commands.json'.

compile_commands_file(_, File) :-
    exists_file('compile_commands.json'),
    absolute_file_name('compile_commands.json', File),
    !.
compile_commands_file(Root, File) :-
    directory_file_path(Root, 'build*/compile_commands.json', Pattern),
    expand_file_name(Pattern, Files),
    map_list_to_pairs(time_file, Files, Pairs),
    sort(1, >=, Pairs, [BuildTime-BuildFile|_]),
    directory_file_path(Root, 'compile_commands.json', RootFile),
    (   exists_file(RootFile),
        time_file(RootFile, RootTime),
        RootTime > BuildTime
    ->  File = RootFile
    ;   File = BuildFile
    ).
