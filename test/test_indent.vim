vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  infoview: {autoopen: false},
  lsp: {enable: false},
}

runtime plugin/lean.vim
filetype plugin indent on
syntax enable

def NewLeanBuffer(lines: list<string>, shift: number = 2)
  enew!
  setline(1, lines)
  setfiletype lean
  execute 'setlocal shiftwidth=' .. shift
  setlocal expandtab
  syntax sync fromstart
enddef

def NextIndent(lines: list<string>, shift: number = 2): number
  NewLeanBuffer(lines + [''], shift)
  return g:LeanVim9Indent(line('$'))
enddef

def Reindent(lines: list<string>): list<string>
  NewLeanBuffer(lines)
  normal! gg=G
  return getline(1, '$')
enddef

assert_equal(2, NextIndent(['structure Foo where']), 'where did not indent')
assert_equal(7, NextIndent(['structure Foo where'], 7), 'shiftwidth was ignored')
assert_equal(2, NextIndent(['example : 2 = 2 := by']), 'by did not indent')
assert_equal(4, NextIndent([
  'example : 37 = 37 := by',
  '  have : 37 = 37 := by',
]), 'nested by did not indent')
assert_equal(6, NextIndent([
  'example {n : Nat} : n = n := by',
  '  induction n with',
  '    | zero =>',
]), 'match branch did not indent')
assert_equal(6, NextIndent([
  'example :',
  '    2 =',
]), 'equals did not indent')

# Focused branches align continuation lines after the multibyte focus marker.
assert_equal(4, NextIndent([
  'example {n : Nat} : n = n := by',
  '  cases n',
  '  · have : 0 = 0 := rfl',
]), 'focus branch continuation was not aligned')
assert_equal(6, NextIndent([
  'theorem foo : 37 = 37 := by',
  '  · have : 37 = 37 := by',
]), 'nested proof after a focus marker did not indent')

# A completed standalone goal closes the proof indentation, but inline
# placeholders do not.
assert_equal(0, NextIndent([
  'example : 37 = 37 := by',
  '  sorry',
]), 'standalone sorry did not dedent')
assert_equal(2, NextIndent([
  'example : 37 = 37 := by',
  '  have : 37 = 37 := sorry',
]), 'inline sorry incorrectly dedented')
assert_equal(2, NextIndent([
  'example : 37 = 37 := by',
  '  suffices h : 73 = 73 from sorry',
]), 'sorry after from incorrectly dedented')
assert_equal(2, NextIndent([
  'example : 37 = 37 ∧ 73 = 73 := by',
  '  constructor',
  '  · sorry',
]), 'focused sorry did not align the next focus')

assert_equal(4, NextIndent(['example :']), 'type continuation was not double-indented')
assert_equal(2, NextIndent([
  'example :',
  '    2 = 2 :=',
]), 'body after a double-indented type did not dedent')
assert_equal(4, NextIndent([
  'example : 2 = 2 ∧ 3 = 3 := by',
  '  exact ⟨rfl,',
]), 'anonymous literal contents did not indent')

# Reindent complete buffers to exercise declaration and syntax-state handling.
assert_equal([
  'structure Foo where',
  '  field : Nat',
  '',
  'def value := 37',
  '',
  'instance : ToString String :=',
  '  inferInstance',
  'structure Bar where',
  'attribute [instance] Foo',
], Reindent([
  'structure Foo where',
  'field : Nat',
  '',
  'def value := 37',
  '',
  'instance : ToString String :=',
  'inferInstance',
  'structure Bar where',
  'attribute [instance] Foo',
]), 'top-level declarations were misindented')

assert_equal([
  'example : True := by',
  '  exact True.intro',
  'theorem next : True := True.intro',
], Reindent([
  'example : True := by',
  '  exact True.intro',
  'theorem next : True := True.intro',
]), 'a declaration after a proof inherited tactic indentation')

assert_equal([
  'def pair : Nat × Nat := {',
  '  fst := 37',
  '  snd := 73',
  '}',
], Reindent([
  'def pair : Nat × Nat := {',
  'fst := 37',
  'snd := 73',
  '}',
]), 'structure notation was misindented')

assert_equal([
  '-- Do not',
  '--       reindent',
  '-- comments :=',
], Reindent([
  '-- Do not',
  '--       reindent',
  '-- comments :=',
]), 'comment indentation was changed')

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
