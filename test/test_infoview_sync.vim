vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var rpc_log = root .. '/test-infoview-sync-rpc.log'
delete(rpc_log)
execute 'set runtimepath^=' .. fnameescape(root)
import './support/harness.vim' as harness
g:lean_config = {
  infoview: {autoopen: false, update_cooldown: 0},
  inlay_hints: {enable: false},
  semantic_highlighting: {enable: false},
  lsp: {
    command: [
      'python3', root .. '/test/support/fake_lean_server.py', rpc_log, '2', 'ready', 'none',
    ],
    change_delay: 500,
  },
}
runtime plugin/lean.vim
filetype plugin indent on
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')

def Messages(): list<any>
  return mapnew(filereadable(rpc_log) ? readfile(rpc_log) : [],
    (_, line) => json_decode(line))
enddef

def GoalsReady(): bool
  var view = lean#InfoviewState()
  return index(view.goal, '⊢ Nat') >= 0 && view.term_goal ==# ['Nat']
enddef

def CountGoals(buffer_number: number): number
  var uri = lean#util#UriFromBuf(buffer_number)
  return len(filter(harness.Messages(rpc_log, '$/lean/plainGoal'), (_, message) =>
    get(message.params.textDocument, 'uri', '') ==# uri))
enddef

def Notify(buffer_number: number, method: string, params: dict<any>)
  var done = false
  lean#lsp#Request(buffer_number, 'test/notify', {method: method, params: params},
    (result, error) => {
      done = true
    })
  assert_true(harness.WaitFor(() => done), 'test notification was not delivered')
enddef

def Progress(buffer_number: number, processing: bool)
  Notify(buffer_number, '$/lean/fileProgress', {
    textDocument: {uri: lean#util#UriFromBuf(buffer_number)},
    processing: processing ? [{
      range: {start: {line: 1, character: 0}, end: {line: 1, character: 0}},
      kind: 1,
    }] : [],
  })
enddef

assert_true(harness.WaitFor(() => get(lean#LspStatus(), 'initialized', false)))
var source = bufnr()
cursor(2, 1)
lean#InfoviewOpen()
assert_true(harness.WaitFor(GoalsReady), 'initial goals did not arrive')

# A goal query during a debounced edit must follow didChange on the wire.
setline(2, '  exact 43')
lean#lsp#DidChange(source)
var version = getbufvar(source, 'lean_lsp_version', 0)
setline(2, '  exact 44')
lean#lsp#DidChange(source)
assert_equal(version, getbufvar(source, 'lean_lsp_version', 0),
  'test did not queue a debounced edit')
lean#infoview#Update(source)
assert_true(harness.WaitFor(GoalsReady), 'goals after the edit did not arrive')
var messages = Messages()
var last_goal = -1
var last_change = -1
for index in range(len(messages))
  if get(messages[index], 'method', '') ==# '$/lean/plainGoal'
    last_goal = index
  elseif get(messages[index], 'method', '') ==# 'textDocument/didChange'
    last_change = index
  endif
endfor
assert_equal(version + 1, getbufvar(source, 'lean_lsp_version', 0),
  'goal request did not flush the pending edit')
assert_true(last_change >= 0 && last_change < last_goal,
  'goal request preceded the latest didChange')
if last_change >= 0
  assert_equal('4', messages[last_change].params.contentChanges[0].text,
    'goal request used the previous document contents')
endif

# TextChangedI is skipped while the completion popup is visible.
setline(2, '  exact 45')
doautocmd <nomodeline> TextChangedP
assert_true(harness.WaitFor(() => getbufvar(source, 'lean_lsp_version', 0) > version + 1),
  'edits made with the completion popup open did not reach Lean')
assert_true(harness.WaitFor(GoalsReady))

# Processing can finish while focus is in a different tab. Refresh the
# original source and preserve the active tab's infoview and cursor.
var first = lean#InfoviewState()
var first_tab = tabpagenr()
var goal_count = CountGoals(source)
tabnew
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Editor.lean')
lean#InfoviewOpen()
assert_true(harness.WaitFor(GoalsReady))
var second = lean#InfoviewState()
var active_win = win_getid()
Progress(source, true)
Progress(source, false)
assert_true(harness.WaitFor(() => CountGoals(source) > goal_count),
  'finishing processing did not request fresh goals')
assert_equal(active_win, win_getid(), 'background refresh changed the active window')
assert_equal(second.sequence, lean#InfoviewState().sequence,
  'another buffer finishing processing refreshed this tab')
execute 'tabnext ' .. first_tab
assert_true(harness.WaitFor(GoalsReady))
assert_equal(first.sequence + 1, lean#InfoviewState().sequence,
  'finishing processing did not refresh the background infoview')
assert_equal(first.position, lean#InfoviewState().position,
  'background refresh queried the other tab cursor')

# Repeated idle and diagnostic notifications must not generate goal traffic.
var sequence = lean#InfoviewState().sequence
Progress(source, false)
Progress(source, false)
Notify(source, 'textDocument/publishDiagnostics', {
  uri: lean#util#UriFromBuf(source), diagnostics: [],
})
assert_equal(sequence, lean#InfoviewState().sequence,
  'idle notifications caused redundant goal requests')

lean#InfoviewPinTogglePause()
Progress(source, true)
Progress(source, false)
assert_equal(sequence + 1, lean#InfoviewState().sequence,
  'processing notifications refreshed a paused infoview')
lean#InfoviewPinTogglePause()
assert_true(harness.WaitFor(GoalsReady))
lean#InfoviewClose()
sequence = lean#InfoviewState().sequence
Progress(source, true)
Progress(source, false)
assert_equal(sequence, lean#InfoviewState().sequence,
  'processing notifications refreshed a closed infoview')

harness.Stop(rpc_log)
if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
delete(rpc_log)
qa!
