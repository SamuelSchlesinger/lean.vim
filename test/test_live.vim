vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  infoview: {autoopen: false, update_delay: 20},
  lsp: {stderr: false},
}

runtime plugin/lean.vim
filetype plugin indent on
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')

def WaitFor(Predicate: func(): any, timeout_ms: number = 10000): bool
  var elapsed = 0
  while elapsed < timeout_ms
    if Predicate()
      return true
    endif
    sleep 20m
    elapsed += 20
  endwhile
  return Predicate()
enddef

assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'real Lean server did not initialize')
cursor(2, 1)
lean#InfoviewOpen()
assert_true(WaitFor(() => index(get(lean#InfoviewState(), 'goal', []), '⊢ Nat') >= 0),
  'real Lean server did not return the expected tactic goal: ' .. string(lean#InfoviewState()))

var state = lean#InfoviewState()
win_gotoid(state.source_winid)
setline(2, '  exact True')
lean#OnChanged(state.source_bufnr)
assert_true(WaitFor(() => !empty(lean#lsp#DiagnosticsAt(state.source_bufnr, 1))),
  'real Lean server did not accept the full-document didChange notification')

lean#InfoviewClose()
execute 'edit! ' .. fnameescape(root .. '/test/fixtures/LakeProject/LeanVimFixture.lean')
assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'lake serve did not initialize for the Lake fixture')
assert_equal('lake', lean#LspStatus().command[0])
assert_equal(root .. '/test/fixtures/LakeProject', lean#LspStatus().root)
assert_false(empty(lean#CurrentSearchPaths()))

lean#Stop()
if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
