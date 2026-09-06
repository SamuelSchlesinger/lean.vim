vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
import './support/harness.vim' as harness
g:lean_config = {
  infoview: {autoopen: false, update_delay: 20},
  lsp: {stderr: false},
}

runtime plugin/lean.vim
filetype plugin indent on
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')


assert_true(harness.WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'real Lean server did not initialize')
cursor(2, 1)
lean#InfoviewOpen()
assert_true(harness.WaitFor(() => index(get(lean#InfoviewState(), 'goal', []), '⊢ Nat') >= 0),
  'real Lean server did not return the expected tactic goal: ' .. string(lean#InfoviewState()))

# A live pin follows an inserted line and re-elaborates when the expected
# type changes. This verifies the feature against Lean, not just a JSON stub.
lean#InfoviewAddPin()
assert_true(harness.WaitFor(() => index(get(get(get(lean#InfoviewState(), 'pins', []), 0, {}), 'lines', []), '⊢ Nat') >= 0))
var pinned_source = bufnr()
append(0, '-- live pin movement')
listener_flush(pinned_source)
lean#OnChanged(pinned_source)
assert_true(harness.WaitFor(() => lean#InfoviewState().pins[0].line == 2))
setline(2, 'def answer : Bool := by')
listener_flush(pinned_source)
lean#OnChanged(pinned_source)
assert_true(harness.WaitFor(() => index(lean#InfoviewState().pins[0].lines, '⊢ Bool') >= 0, 10000),
  'real Lean pin did not refresh its expected type: ' .. string(lean#InfoviewState().pins))
lean#InfoviewClearPins()
edit!
lean#OnChanged(pinned_source)

var state = lean#InfoviewState()
win_gotoid(state.source_winid)
setline(2, '  exact True')
lean#OnChanged(state.source_bufnr)
assert_true(harness.WaitFor(() => !empty(lean#lsp#DiagnosticsAt(state.source_bufnr, 1))),
  'real Lean server did not accept the incremental didChange notification')

lean#InfoviewClose()

# Exercise the default manual completion flow against Lean itself, including
# applying the server's real textEdit instead of only checking its JSON.
setline(5, '#check Nat.su')
var completion_poll = {elapsed: 0, selected: false, labels: []}
def AcceptSucc(_timer: number)
  if pumvisible()
    var items = complete_info(['items']).items
    completion_poll.labels = mapnew(items, (_, item) => get(item, 'abbr', item.word))
    var index = indexof(items, (_, item) =>
      get(item, 'abbr', item.word) =~# '^\%(Nat\.\)\?succ$')
    if index >= 0
      completion_poll.selected = true
      feedkeys(repeat("\<C-n>", index + 1) .. "\<C-y>\<Esc>", 'nt')
      return
    endif
  endif
  completion_poll.elapsed += 20
  if completion_poll.elapsed >= 10000
    feedkeys("\<Esc>", 'nt')
  else
    timer_start(20, AcceptSucc)
  endif
enddef
timer_start(20, AcceptSucc)
feedkeys("5GA\<C-x>\<C-o>", 'xt!')
assert_true(completion_poll.selected,
  'real Lean completion did not offer Nat.succ: ' .. string(completion_poll.labels))
assert_equal('#check Nat.succ', getline(5), 'real Lean completion applied the wrong text edit')

execute 'edit! ' .. fnameescape(root .. '/test/fixtures/LakeProject/LeanVimFixture.lean')
assert_true(harness.WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'lake serve did not initialize for the Lake fixture')
assert_equal('lake', lean#LspStatus().command[0])
assert_equal(root .. '/test/fixtures/LakeProject', lean#LspStatus().root)
var cwd_before_search = getcwd()
g:lean_test_dir_changes = 0
augroup lean_test_directory_events
  autocmd!
  autocmd DirChanged * g:lean_test_dir_changes += 1
augroup END
assert_false(empty(lean#CurrentSearchPaths()))
assert_equal(cwd_before_search, getcwd(), 'search-path lookup changed Vim working directory')
assert_equal(0, g:lean_test_dir_changes, 'search-path lookup fired DirChanged')

lean#Stop()
if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
