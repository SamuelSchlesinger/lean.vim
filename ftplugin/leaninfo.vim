vim9script

if exists('b:did_ftplugin')
  finish
endif
b:did_ftplugin = 1
b:did_indent = 1
setlocal buftype=nofile bufhidden=hide noswapfile nomodifiable
# Diagnostics regularly exceed the infoview width; wrap at word boundaries
# and keep the hanging indent so hypotheses stay readable.
setlocal wrap linebreak breakindent nonumber norelativenumber signcolumn=no
