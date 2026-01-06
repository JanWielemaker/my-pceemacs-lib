# Extending the SWI-Prolog built-in editor pceEmacs

This directory holds some  examples  for   extending  various  modes  in
pceEmacs. Install this directory  as   `xpce/emacs`  in  the SWI-Prologs
configuration directory. On a UNIX system by using XDG, this means

```
cd ~/.config/swi-prolog
mkdir -p xpce
cd xpce
git clone https://github.com/JanWielemaker/my-pceemacs-lib.git emacs
```

## Using LSP (Language Server Protocol)

### Using Vale-ls

[Vale](https://vale.sh/) is _a linter  for   prose_.  There are packages
dealing with spelling as  well  as   validating  that  text  conforms to
specific style guides. The program  `vale-ls`   is  a wrapper around the
`vale` CLI that implements the language   server  protocol (LSP). As is,
this repository integrates Vale for these modes:

  - Markdown
  - LaTeX
  - C

Vale supports programming languages, by  default scanning comments only.
Ideally, we want to add Prolog. This is not so easy though, as Vale does
not allow defining the comment syntax. To do   so, we need to add Prolog
as a supported language, which implies  adding a tree-sitter grammar for
it.   Tree sitter grammars exist for Prolog:

  - https://github.com/Rukiza/tree-sitter-prolog
  - https://github.com/gruhn/tree-sitter-prolog
    (fork of above)
  - https://codeberg.org/foxy/tree-sitter-prolog
    (JavaScript)
  - https://github.com/jamesnvc/tree-sitter-prolog
    (JavaScript)
  - https://github.com/foxyseta/tree-sitter-prolog
    (C after all?)
  - https://github.com/Desdaemon/tree-sitter-prolog (3 years)
