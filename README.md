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

This repository implements a prototype integration   of LSP servers into
PceEmacs.  Notes:

  - Requires SWI-Prolog 10.1.2 or the git version
  - Eventually, most of this will probably be moved into PceEmacs itself.
    as is, there are some pending design issues.  Notably:
    - How must an LSP be connected to a mode?  As is, methods on the mode
      need to be redefined to call the LSP.
    - How to fallback if the desired LSP does not exist?


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
