vim9script

if exists('b:did_indent')
  finish
endif
b:did_indent = 1

setlocal indentexpr=LeanVim9Indent(v:lnum)
setlocal indentkeys=o,O,0=end,0=else,0=where,0=|

def! g:LeanVim9Indent(lnum: number): number
  var previous = prevnonblank(lnum - 1)
  if previous == 0
    return 0
  endif
  var amount = indent(previous)
  var previous_text = getline(previous)
  var current = getline(lnum)
  if previous_text =~# '\v(\b(by|do|where|then|else|match|with)\s*$|(:=|=>|\{|\[|\()\s*$)'
    amount += shiftwidth()
  endif
  if current =~# '^\s*\%(end\|else\|where\|}\|]\|)\)\>' || current =~# '^\s*[}\])]'
    amount -= shiftwidth()
  endif
  return max([0, amount])
enddef

b:undo_indent = 'setlocal indentexpr< indentkeys<'

defcompile
