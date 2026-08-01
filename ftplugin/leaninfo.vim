vim9script

if exists('b:did_ftplugin')
  finish
endif
b:did_ftplugin = 1
b:did_indent = 1
setlocal buftype=nofile bufhidden=hide noswapfile nomodifiable
setlocal nowrap nonumber norelativenumber signcolumn=no
