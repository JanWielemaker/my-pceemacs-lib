# Extending the SWI-Prolog built-in editor PceEmacs

This directory holds some  examples  for   extending  various  modes  in
PceEmacs. Install this directory  as   `xpce/emacs`  in  the SWI-Prologs
configuration directory. On a UNIX system by using XDG, this means

```
cd ~/.config/swi-prolog
mkdir -p xpce
cd xpce
git clone https://github.com/JanWielemaker/my-pceemacs-lib.git emacs
```

## Using LSP (Language Server Protocol)

The LSP client and the registry of LSP servers are part of PceEmacs
(`library(emacs/lsp_client)` and `library(emacs/lsp_registry)`).  This
repository adds the editor features on top of them, which are being
moved into PceEmacs as well.  Notes:

  - Requires the git version of SWI-Prolog.
  - Servers are registered using the multifile predicate
    `lsp_registry:lsp_server/2`, which also tells which _roles_ a server
    plays (e.g., `highlight`, `symbol`, `complete`, `spelling`).  A mode
    asks for a server by role.  The class variable `lsp_roles` of a mode
    overrules the registry.  PceEmacs registers `clangd`; `vale.pl`
    registers `vale-ls`.


### Using clangd

The program `clangd` is a comprehensive LSP  for C and C++. Currently it
is used to:

  - Offer syntax highlighting
  - Implement find-definition and find-references
  - Show the `clangd` diagnostics in the margin.

### Using Vale-ls

[Vale](https://vale.sh/) is _a linter  for   prose_.  There are packages
dealing with spelling as  well  as   validating  that  text  conforms to
specific style guides. The program  `vale-ls`   is  a wrapper around the
`vale` CLI that implements the language   server  protocol (LSP). As is,
this repository integrates Vale for these modes:

  - Markdown
  - LaTeX
  - C
  - Prolog

The Prolog support uses a modified version of `vale`.  This version
can be built from the following sources:

  - https://github.com/JanWielemaker/vale
    Using branch `prolog`.
  - https://github.com/JanWielemaker/go-tree-sitter
    Using branch `prolog`.

Clone both repositories in the same   parent directory, install `golang`
and run `make` in the `vale` directory to create `bin/vale`.
