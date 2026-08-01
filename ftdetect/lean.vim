vim9script

augroup lean_vim9_filetype
  autocmd!
  autocmd BufRead,BufNewFile *.lean setfiletype lean
augroup END
