vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
import './support/harness.vim' as harness
var rpc_log = root .. '/test-pins-rpc.log'
delete(rpc_log)
g:lean_config = {
  infoview: {autoopen: false}, inlay_hints: {enable: false},
  semantic_highlighting: {enable: false},
  lsp: {command: ['python3', root .. '/test/support/fake_lean_server.py', rpc_log], change_delay: 0},
}
runtime plugin/lean.vim
filetype plugin indent on
set hidden
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')
assert_true(harness.WaitFor(() => get(lean#LspStatus(), 'initialized', false)))
var source = bufnr()
var source_window = win_getid()
harness.Scenario(source, '$/lean/plainGoal', 'source-goal')
cursor(2, 3)
lean#InfoviewOpen()
lean#InfoviewAddPin()

def Pin(index: number = 0): dict<any>
  return get(get(lean#InfoviewState(), 'pins', []), index, {})
enddef

def HasGoal(index: number, text: string): bool
  return index(get(Pin(index), 'lines', []), text) >= 0
enddef

assert_true(harness.WaitFor(() => HasGoal(0, 'line 2, column 3')), 'initial pin goal missing')
append(0, '-- inserted above the pin')
listener_flush(source)
lean#OnChanged(source)
assert_true(harness.WaitFor(() => HasGoal(0, 'line 3, column 3')), 'pin did not follow inserted lines: ' .. string(Pin()))
feedkeys("3G0iα😊\<Esc>", 'xt')
listener_flush(source)
lean#OnChanged(source)
assert_true(harness.WaitFor(() => HasGoal(0, 'line 3, column 6')), 'pin did not track UTF-16 columns')
setline(3, 'prefix ' .. getline(3))
listener_flush(source)
lean#OnChanged(source)
assert_true(harness.WaitFor(() => HasGoal(0, 'line 3, column 13')), 'programmatic replacement lost its anchor: ' .. string(Pin()))
deletebufline(source, 1)
listener_flush(source)
lean#OnChanged(source)
assert_true(harness.WaitFor(() => HasGoal(0, 'line 2, column 13')), 'pin did not follow a deleted preceding line')

var pin_header = indexof(getbufline(lean#InfoviewState().bufnr, 1, '$'), (_, text) => text =~# '^Pin ') + 1
win_gotoid(bufwinid(lean#InfoviewState().bufnr))
cursor(pin_header, 1)
lean#infoview#JumpToTarget()
assert_equal([2, 16], [line('.'), col('.')], 'pin jump did not follow its updated Unicode position')

# Pins in another source stay live when the infoview follows a new buffer.
execute 'split ' .. fnameescape(root .. '/test/fixtures/Editor.lean')
var other = bufnr()
cursor(1, 2)
lean#InfoviewAddPin()
assert_true(harness.WaitFor(() => HasGoal(1, 'line 1, column 2')))
var second_goal = copy(Pin(1).lines)
setbufline(source, 2, 'changed ' .. getbufline(source, 2)[0])
lean#OnChanged(source)
assert_true(harness.WaitFor(() => HasGoal(0, 'line 2, column 21')), 'hidden source pin did not refresh')
assert_equal(second_goal, Pin(1).lines, 'updating one pin changed another source pin')

# Pausing suppresses goal requests, while anchors continue tracking edits.
lean#InfoviewPinTogglePause()
var paused_goal = copy(Pin().lines)
var requests_before = len(harness.Messages(rpc_log, '$/lean/plainGoal'))
appendbufline(source, 0, '-- paused insertion')
listener_flush(source)
harness.Barrier(other)
assert_equal(2, Pin().line)
assert_equal(paused_goal, Pin().lines)
execute 'file ' .. fnameescape(root .. '/test/fixtures/PinsRenamed.lean')
assert_equal(lean#util#UriFromBuf(other), Pin(1).uri, 'paused pin kept its old file name')
execute 'file ' .. fnameescape(root .. '/test/fixtures/Editor.lean')
assert_equal(requests_before, len(harness.Messages(rpc_log, '$/lean/plainGoal')),
  'paused pins kept requesting goals')
lean#InfoviewPinTogglePause()
assert_true(harness.WaitFor(() => HasGoal(0, 'line 3, column 21')), 'resumed pin did not refresh')

# A server restart re-queries every source, including the hidden pin.
var before_restart = len(harness.Messages(rpc_log, '$/lean/plainGoal'))
lean#lsp#RestartServer(other)
harness.Scenario(other, '$/lean/plainGoal', 'source-goal')
assert_true(harness.WaitFor(() => get(lean#LspStatus(), 'initialized', false)))
assert_true(harness.WaitFor(() => len(harness.Messages(rpc_log, '$/lean/plainGoal')) >= before_restart + 2))
harness.Barrier(other)
var reopened = harness.Messages(rpc_log, '$/lean/plainGoal')[before_restart :]
for target in [source, other]
  assert_true(indexof(reopened, (_, message) => message.params.textDocument.uri ==# lean#util#UriFromBuf(target)) >= 0,
    'restart did not refresh a pinned source')
endfor
assert_true(harness.WaitFor(() => HasGoal(0, 'line 3, column 21')))

# Unloaded sources retain a visible explanation; reloading restores tracking.
execute 'bunload! ' .. source
assert_true(harness.WaitFor(() => HasGoal(0, 'The pinned source buffer is no longer loaded.')))
bufload(source)
lean#lsp#Attach(source)
assert_true(harness.WaitFor(() => !HasGoal(0, 'The pinned source buffer is no longer loaded.')))
assert_true(harness.WaitFor(() => join(Pin().lines, ' ') =~# 'line '))

# Two tab-local infoviews share a source but own separate pin requests. Closing
# one tab must release only its anchors and preserve the other view.
var original_info = lean#InfoviewState().bufnr
execute 'tab sbuffer ' .. other
cursor(3, 1)
lean#InfoviewAddPin()
assert_true(harness.WaitFor(() => HasGoal(0, 'line 3, column 1')))
var extra_pin = Pin().id
var extra_info = lean#InfoviewState().bufnr
appendbufline(other, 0, '-- shared insertion')
listener_flush(other)
lean#OnChanged(other)
assert_true(harness.WaitFor(() => index(getbufline(original_info, 1, '$'), 'line 2, column 2') >= 0),
  'a pin reply rendered into the wrong tab')
assert_true(harness.WaitFor(() => index(getbufline(extra_info, 1, '$'), 'line 4, column 1') >= 0))
tabclose
assert_true(harness.WaitFor(() => !bufexists(extra_info)))
assert_equal(2, len(lean#InfoviewState().pins))
assert_equal({}, prop_find({bufnr: other, type: 'LeanLivePin', id: extra_pin,
  both: true, lnum: 1, col: 1}, 'f'), 'closing a tab leaked its pin anchor')

# Clear pins while their replies are held. Releasing those replies must not
# recreate pins or their properties, even if the server ignores cancellation.
harness.Hold(other, '$/lean/plainGoal', 'cleared')
setbufline(source, 1, '-- changed again')
lean#OnChanged(source)
harness.Barrier(other)
lean#InfoviewClearPins()
harness.Release(other, 'cleared')
assert_equal([], lean#InfoviewState().pins)
for target in [source, other]
  assert_equal({}, prop_find({bufnr: target, type: 'LeanLivePin', lnum: 1, col: 1}, 'f'))
endfor
harness.Stop(rpc_log)
delete(rpc_log)
if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
