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
set nowrap
lean#InfoviewOpen()
var first = lean#InfoviewState()
assert_equal(bufnr(root .. '/test/fixtures/Basic.lean'), first.source_bufnr)
assert_true(!empty(win_findbuf(first.bufnr)), 'first infoview was not visible')
assert_true(has_key(get(first, 'line_targets', {}), '1'),
  'infoview render did not record the header jump target')

# Long diagnostics must wrap in the infoview even when the user has global
# 'nowrap', and the window-local options must survive a close/reopen because
# the reused buffer gets a brand-new window each time.
assert_true(getwinvar(bufwinid(first.bufnr), '&wrap'),
  'infoview window did not enable wrap')
lean#InfoviewClose()
lean#InfoviewOpen()
first = lean#InfoviewState()
assert_true(getwinvar(bufwinid(first.bufnr), '&wrap'),
  'reopened infoview window did not re-enable wrap')
assert_true(getwinvar(bufwinid(first.bufnr), '&linebreak'),
  'reopened infoview window did not re-enable linebreak')
assert_true(getwinvar(bufwinid(first.bufnr), '&breakindent'),
  'reopened infoview window did not re-enable breakindent')

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

# Regression: with the source window already closed, the infoview can be the
# last window in the last tab. Closing it (interactively or from VimLeavePre
# via CloseAll) must not raise E444; the window shows an empty buffer.
silent! tabonly!
sleep 20m
execute 'edit! ' .. fnameescape(root .. '/test/fixtures/Basic.lean')
silent! only!
lean#InfoviewOpen()
var last_view = lean#InfoviewState()
win_gotoid(bufwinid(last_view.source_bufnr))
close
assert_equal(1, winnr('$'), 'expected the infoview to be the last window')
var close_error = ''
try
  lean#InfoviewClose()
catch
  close_error = v:exception
endtry
assert_equal('', close_error, 'closing a last-window infoview errored')
assert_true(empty(win_findbuf(last_view.bufnr)),
  'the infoview buffer was still displayed after a last-window close')

# The same path through CloseAll (what VimLeavePre runs) must also be quiet.
execute 'edit! ' .. fnameescape(root .. '/test/fixtures/Basic.lean')
lean#InfoviewOpen()
win_gotoid(bufwinid(lean#InfoviewState().source_bufnr))
close
try
  lean#InfoviewCloseAll()
catch
  close_error = v:exception
endtry
assert_equal('', close_error, 'CloseAll errored on a last-window infoview')

lean#InfoviewCloseAll()
if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
