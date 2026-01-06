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

### Using Vale

[Vale](https://vale.sh/) is _a linter  for   prose_.  There are packages
dealing with spelling as  well  as   validating  that  text  conforms to
specific style guides.
