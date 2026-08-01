vim9script

if exists('b:did_ftplugin')
  finish
endif
b:did_ftplugin = 1

setlocal expandtab shiftwidth=2 softtabstop=2
setlocal commentstring=--\ %s
setlocal comments=s0:/-,mb:\ ,ex:-/,:--
setlocal iskeyword=a-z,A-Z,_,48-57,192-255,!,',?,#
setlocal includeexpr=substitute(v:fname,'\.','/','g').'.lean'
setlocal suffixesadd=.lean
setlocal matchpairs+=⟨:⟩,‹:›,«:»

if exists('g:loaded_matchit') && !exists('b:match_words')
  b:match_ignorecase = 0
  b:match_words = '\<\%(namespace\|section\)\s\+\([^«»]\{-}\>\|«.\{-}»\):\<end\s\+\1,'
    .. '^\s*section\s*$:^end\s*$,'
    .. '\<if\>:\<then\>:\<else\>,'
    .. '/\-:\-/'
endif

if exists('g:loaded_switch')
  b:switch_definitions = [
    ['true', 'false'],
    ['#check', '#eval', '#reduce'],
    ['sorry', 'exact?', 'try?', 'apply?'],
    ['aesop', 'aesop?'],
    ['grind', 'grind?'],
    ['=', '≠'], ['∈', '∉'], ['∪', '∩'], ['∀', '∃'], ['∧', '∨'],
    ['⊥', '⊤'], ['×', '→'], ['Σ', '∑'], ['ℕ', 'ℚ', 'ℝ', 'ℂ'],
  ]
endif

import autoload 'lean.vim' as lean
lean.Attach(bufnr())

b:undo_ftplugin = 'setlocal expandtab< shiftwidth< softtabstop< commentstring< comments< iskeyword< includeexpr< suffixesadd< matchpairs< | unlet! b:match_words b:match_ignorecase b:switch_definitions'
