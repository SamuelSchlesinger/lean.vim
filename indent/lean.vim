vim9script

# Informed by lean.nvim's Lean indentation implementation.
# SPDX-License-Identifier: MIT

if exists('b:did_indent')
  finish
endif
b:did_indent = 1

setlocal indentexpr=g:LeanVim9Indent(v:lnum)
setlocal indentkeys=o,O,0=end,0=else,0=where,0=|

const indent_after = '\%('
  .. '\<by\|\<do\|\<try\|\<finally\|\<then\|\<else\|\<where\|'
  .. '\<from\|\<extends\|\<deriving\|\<:=\|=>\| ='
  .. '\)\s*$'
const never_indent = '^\s*\%('
  .. 'abbrev\s\|attribute\s\|axiom\s\|class\s\|compile_inductive\s\|'
  .. 'def\s\|end\>\|example\>\|import\s\|inductive\s\|instance\s\|'
  .. 'lemma\s\|namespace\>\|opaque\s\|partial_fixpoint\>\|section\>\|'
  .. 'structure\s\|theorem\s\|where\>\|@\['
  .. '\)'

def SyntaxGroups(lnum: number, column: number): list<string>
  var groups: list<string> = []
  for id in synstack(lnum, max([1, column]))
    add(groups, synIDattr(id, 'name'))
  endfor
  return groups
enddef

def IsComment(lnum: number): bool
  if lnum < 1
    return false
  endif
  var column = match(getline(lnum), '\S') + 1
  var id = synID(lnum, max([1, column]), true)
  return synIDattr(synIDtrans(id), 'name') ==# 'Comment'
enddef

def IsDeclarationArgs(lnum: number): bool
  if lnum < 1
    return false
  endif
  var text = getline(lnum)
  var column = match(text, '\S') + 1
  var groups = SyntaxGroups(lnum, max([1, column]))
  return index(groups, 'leanBlockComment') >= 0
    || index(groups, 'leanAttributeArgs') >= 0
enddef

def IsEnclosedAtEnd(lnum: number): bool
  if lnum < 1
    return false
  endif
  var text = getline(lnum)
  var groups = SyntaxGroups(lnum, max([1, strlen(text)]))
  return index(groups, 'leanEncl') >= 0
    || index(groups, 'leanAnonymousLiteral') >= 0
enddef

def SorryAt(lnum: number): number
  if lnum < 1
    return -1
  endif
  var text = getline(lnum)
  var position = match(text, '\<sorry\>\s*$')
  if position < 0
    return -1
  endif
  var groups = SyntaxGroups(lnum, position + 1)
  return empty(groups) || index(groups, 'leanSorry') >= 0 ? position : -1
enddef

def FocusesAt(text: string, indentation: number): bool
  return strpart(text, indentation, strlen('·')) ==# '·'
enddef

def! g:LeanVim9Indent(lnum: number): number
  if lnum <= 1
    return 0
  endif
  if IsComment(lnum - 1)
    return indent(lnum)
  endif

  var previous_text = getline(lnum - 1)
  var current = getline(lnum)
  var shift = shiftwidth()
  var current_indent = indent(lnum)
  if trim(current) ==# '}'
      || (current_indent > 0 && !empty(trim(current))
        && current_indent % shift == 0)
    return current_indent
  elseif current =~# never_indent
    return 0
  endif

  if previous_text =~# ':\s*$'
    return shift * 2
  elseif previous_text =~# ':=\s*$' || previous_text =~# '{\s*$'
    return shift
  endif

  var sorry = SorryAt(lnum - 1)
  if sorry >= 0
    var before = strpart(previous_text, 0, sorry)
    if before !~# ':=\s*' && before !~# '\<from\s*'
      return max([0, sorry - shift - 1])
    endif
  endif

  var previous_indent = indent(lnum - 1)
  if IsEnclosedAtEnd(lnum - 1)
    return IsEnclosedAtEnd(lnum - 2)
      ? previous_indent
      : previous_indent + shift
  endif

  if FocusesAt(previous_text, previous_indent)
    previous_indent += strlen('·')
  endif

  if previous_text =~# indent_after
    return previous_indent + shift
  endif

  if !IsDeclarationArgs(lnum - 1)
    var dedent_one = previous_indent - shift
    var end_of_binders = dedent_one > 0 && previous_text =~# '^\s*[\[({]'
    if end_of_binders
      return dedent_one
    endif
    return previous_indent == 0 ? current_indent : previous_indent
  endif

  return current_indent
enddef

b:undo_indent = 'setlocal indentexpr< indentkeys<'

defcompile
