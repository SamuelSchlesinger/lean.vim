vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
import './support/harness.vim' as harness
import autoload 'lean/requests.vim' as requests
import autoload 'lean/documents.vim' as documents
var rpc_log = root .. '/test-requests-rpc.log'
delete(rpc_log)
g:lean_config = {
  infoview: {autoopen: false}, inlay_hints: {enable: false},
  semantic_highlighting: {enable: false},
  lsp: {command: ['python3', root .. '/test/support/fake_lean_server.py', rpc_log], change_delay: 1000},
}
runtime plugin/lean.vim
filetype plugin indent on
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')
assert_true(harness.WaitFor(() => get(lean#LspStatus(), 'initialized', false)))
var source = bufnr()
var scope = requests.NewScope()
var replies: list<string> = []
var params = lean#util#PositionParams(source)

# The server deliberately ignores cancellation. Deliver the newer operation
# first, followed by its superseded predecessor, without timing assumptions.
harness.Plan(source, 'textDocument/hover', [
  {hold: 'old', result: 'old'}, {hold: 'new', result: 'new'},
])
var old = requests.Begin(scope, source)
requests.Send(old, 'textDocument/hover', params, (result, _error) => {
  add(replies, result)
})
harness.Barrier(source)
var current = requests.Begin(scope, source)
requests.Send(current, 'textDocument/hover', params, (result, _error) => {
  add(replies, result)
})
harness.Release(source, 'new')
harness.Release(source, 'old')
assert_equal(['new'], replies, 'superseded response escaped its request scope')
assert_false(requests.Active(old))
assert_true(requests.IsCurrent(current))
assert_false(empty(harness.Messages(rpc_log, '$/cancelRequest')))

# A local edit invalidates a reply before the debounced didChange increments
# the LSP version. Validity is about the document revision and lifetime.
harness.Plan(source, 'textDocument/hover', [{hold: 'edit', result: 'stale'}])
current = requests.Begin(scope, source)
requests.Send(current, 'textDocument/hover', params, (result, _error) => {
  add(replies, result)
})
var version = b:lean_lsp_version
setline(2, '  exact 100')
assert_equal(version, b:lean_lsp_version)
assert_false(requests.IsCurrent(current))
harness.Release(source, 'edit')
assert_equal(['new'], replies)

# Reopening identical text creates a new document identity and cancels all
# feature requests and timers owned by the old lifetime.
var before_restart = documents.Capture(source)
current = requests.Begin(scope, source)
var timer = {fired: false}
requests.After(current, 0, () => {
  timer.fired = true
})
lean#lsp#RestartFile(source)
assert_false(requests.Active(current), 'file restart kept an old request scope alive')
assert_false(documents.IsCurrent(before_restart), 'identical reopened text reused document identity')
harness.Barrier(source)
assert_false(timer.fired, 'a timer survived the document lifetime that owned it')

# A new process invalidates snapshots even when buffer, URI, and text match.
var before_server = documents.Capture(source)
lean#lsp#RestartServer(source)
assert_true(harness.WaitFor(() => get(lean#LspStatus(), 'initialized', false)))
assert_false(documents.IsCurrent(before_server))
assert_true(documents.IsCurrent(documents.Capture(source)))

# Window-scoped operations reject a late reply after the user changes focus.
harness.Plan(source, 'textDocument/hover', [{hold: 'window', result: 'wrong window'}])
current = requests.Begin(scope, source, true)
requests.Send(current, 'textDocument/hover', params, (result, _error) => {
  add(replies, result)
})
split
harness.Release(source, 'window')
assert_equal(['new'], replies)
requests.Cancel(scope)
close
harness.Stop(rpc_log)
delete(rpc_log)
if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
