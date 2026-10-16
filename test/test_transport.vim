vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
import './support/harness.vim' as harness
import autoload 'lean/requests.vim' as requests
import autoload 'lean/documents.vim' as documents
var rpc_log = root .. '/test-transport-rpc.log'
delete(rpc_log)
g:lean_config = {
  infoview: {autoopen: false}, inlay_hints: {enable: false},
  semantic_highlighting: {enable: false},
  lsp: {command: ['python3', root .. '/test/support/fake_lean_server.py', rpc_log]},
}
runtime plugin/lean.vim
filetype plugin indent on
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')
assert_true(harness.WaitFor(() => get(lean#LspStatus(), 'initialized', false)))
var source = bufnr()

# The server fills stdout before it reads our large Unicode request. Both
# pipes exceed their capacity, so blocking client writes would freeze Vim
# before it can run the timer or receive either response.
var payload = repeat('α😊', 32768)
var replies = {flood: false, echo: false, text: ''}
lean#lsp#Request(source, 'test/flood', {}, (_result, _error) => {
  replies.flood = true
})
lean#lsp#Request(source, 'test/echo', {text: payload}, (result, _error) => {
  replies.text = get(result, 'text', '')
  replies.echo = true
})
assert_true(harness.WaitFor(() => replies.flood && replies.echo, 15000),
  'full-duplex traffic did not drain both pipes')
assert_true(replies.text ==# payload, 'queued writes changed the Unicode payload')

# Reloading a modified file must reopen its document, invalidate old scopes,
# and continue serving requests. This previously hung in didOpen's write.
var before_reload = documents.Capture(source)
var scope = requests.NewScope()
var stale_reply = {received: false}
harness.Hold(source, 'textDocument/hover', 'before-reload')
var context = requests.Begin(scope, source)
requests.Send(context, 'textDocument/hover', lean#util#PositionParams(source),
  (_result, _error) => {
    stale_reply.received = true
  })
harness.Barrier(source)
setline(2, '  exact 43')
lean#OnChanged(source)
edit!
assert_equal('  exact 42', getline(2))
assert_false(documents.IsCurrent(before_reload), 'reload reused the old document lifetime')
assert_false(requests.Active(context), 'reload retained a stale request scope')
harness.Release(source, 'before-reload')
assert_false(stale_reply.received, 'a reply from before reload was delivered')
assert_true(get(lean#LspStatus(), 'initialized', false), 'reload lost the server')
harness.Stop(rpc_log)
delete(rpc_log)
if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
