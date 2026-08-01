vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  infoview: {autoopen: false, update_cooldown: 20},
  lsp: {enable: false},
  semantic_highlighting: {enable: false},
}

runtime plugin/lean.vim
filetype plugin indent on

execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')
lean#InfoviewOpen()
var first = lean#InfoviewState()
assert_equal(bufnr(root .. '/test/fixtures/Basic.lean'), first.source_bufnr)
assert_true(!empty(win_findbuf(first.bufnr)), 'first infoview was not visible')

# BufWinEnter does not fire when moving between two already-visible splits.
# The tab-local infoview must still follow whichever Lean window is active.
var basic_winid = win_getid()
execute 'leftabove split ' .. fnameescape(root .. '/test/fixtures/Editor.lean')
var editor_winid = win_getid()
assert_equal(bufnr(root .. '/test/fixtures/Editor.lean'),
  lean#InfoviewState().source_bufnr, 'infoview did not follow a newly opened Lean split')
win_gotoid(basic_winid)
assert_equal(bufnr(root .. '/test/fixtures/Basic.lean'),
  lean#InfoviewState().source_bufnr, 'infoview did not follow WinEnter to an existing split')
win_gotoid(editor_winid)
assert_equal(bufnr(root .. '/test/fixtures/Editor.lean'),
  lean#InfoviewState().source_bufnr, 'infoview did not follow back to the second split')
close
win_gotoid(basic_winid)
first = lean#InfoviewState()

tabnew
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Editor.lean')
lean#InfoviewOpen()
var second = lean#InfoviewState()
assert_equal(bufnr(root .. '/test/fixtures/Editor.lean'), second.source_bufnr)
assert_notequal(first.bufnr, second.bufnr, 'two tabs shared one infoview buffer')

# A trailing update belongs to the tab which scheduled it, even if its timer
# fires after the user switches tabs.
tabfirst
var first_sequence = lean#InfoviewState().sequence
lean#OnCursorMoved(first.source_bufnr)
lean#OnCursorMoved(first.source_bufnr)
assert_equal(first_sequence + 1, lean#InfoviewState().sequence,
  'first infoview update was not on the leading edge')
tabnext
sleep 30m
tabfirst
assert_equal(first_sequence + 2, lean#InfoviewState().sequence,
  'trailing infoview update was lost or applied to the wrong tab')

# Closing the first tab renumbers the second from tab 2 to tab 1. Stable
# tab-local identity must keep the second view rather than selecting the old
# views['1'] entry.
tabclose
sleep 20m
var surviving = lean#InfoviewState()
assert_equal(second.bufnr, surviving.bufnr, 'tab renumbering selected the closed tab infoview')
assert_equal(second.source_bufnr, surviving.source_bufnr,
  'tab renumbering selected the closed tab source')
assert_false(bufexists(first.bufnr), 'closed-tab infoview buffer was leaked')

# A globally defined command should fail softly when invoked in a tab which
# has neither a Lean source nor an infoview.
tabnew
enew!
setfiletype text
var navigation_error = ''
try
  lean#GotoInfoview()
  lean#InfoviewAddPin()
catch
  navigation_error = v:exception
endtry
assert_equal('', navigation_error, 'infoview commands errored outside a Lean tab')

lean#InfoviewCloseAll()
if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
