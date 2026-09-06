vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var rpc_log = root .. '/test-request-sync-rpc.log'
delete(rpc_log)
execute 'set runtimepath^=' .. fnameescape(root)
import './support/harness.vim' as harness
g:lean_config = {
  infoview: {autoopen: false},
  semantic_highlighting: {enable: false},
  inlay_hints: {enable: false},
  lsp: {command: ['python3', root .. '/test/support/fake_lean_server.py', rpc_log],
    change_delay: 1000},
}
runtime plugin/lean.vim
filetype plugin indent on
set hidden
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')


assert_true(harness.WaitFor(() => get(lean#LspStatus(), 'initialized', false)))
var source = bufnr()
var uri = lean#util#UriFromBuf(source)
setline(2, '  exact 43')
lean#lsp#DidChange(source)
var synced_version = b:lean_lsp_version
setline(2, '  exact 44')
lean#lsp#DidChange(source)
assert_equal(synced_version, b:lean_lsp_version, 'test did not leave a pending change')

# A matching LSP version alone is insufficient while newer text is pending.
assert_false(lean#lsp#ApplyWorkspaceEdit({documentChanges: [{
  textDocument: {uri: uri, version: synced_version},
  edits: [{range: {start: {line: 1, character: 8}, end: {line: 1, character: 10}},
    newText: '99'}],
}]}), 'workspace edit overwrote text newer than its server version')
assert_equal('  exact 44', getline(2))

var replied = {done: false}
lean#lsp#Request(source, '$/lean/plainGoal', lean#util#PositionParams(source),
  (_result, _error) => extend(replied, {done: true}))
assert_true(harness.WaitFor(() => replied.done))
var messages = mapnew(readfile(rpc_log), (_, line) => json_decode(line))
var request_index = indexof(messages, (_, message) =>
  get(message, 'method', '') ==# '$/lean/plainGoal')
assert_true(request_index > 0)
assert_true(indexof(messages[: request_index - 1], (_, message) =>
  get(message, 'method', '') ==# 'textDocument/didChange'
    && get(message.params.contentChanges[0], 'text', '') ==# '4') >= 0,
  'goal request reached Lean before the pending text change')

# A delayed unversioned rename must not overwrite a later edit, even in
# another open buffer in the same project.
execute 'split ' .. fnameescape(root .. '/test/fixtures/Editor.lean')
var other = bufnr()
var rename = {done: false, applied: false}
harness.Hold(source, 'textDocument/rename', 'stale-rename')
lean#lsp#Request(source, 'textDocument/rename', {
  textDocument: {uri: uri}, position: {line: 0, character: 4}, newName: 'renamed',
}, (result, error) => extend(rename, {
  done: true, applied: type(error) != v:t_dict && lean#lsp#ApplyWorkspaceEdit(result),
}))
setline(1, '-- edited while rename was pending')
harness.Release(source, 'stale-rename')
assert_true(harness.WaitFor(() => rename.done))
assert_false(rename.applied, 'stale unversioned rename was applied')
assert_equal('-- edited while rename was pending', getline(1))

# Recovering a crashed project from a new buffer must reopen its other
# buffers as well. Restarting from an unattached buffer clears the backoff
# without waiting 30 seconds and exercises the automatic start path.
lean#lsp#Notify(source, 'test/exit', {})
assert_true(harness.WaitFor(() => !get(lean#LspStatus(), 'running', true)))
noautocmd enew
noautocmd execute 'file ' .. fnameescape(root .. '/test/fixtures/Recovery.lean')
noautocmd setlocal filetype=lean
lean#lsp#RestartServer(bufnr())
assert_true(harness.WaitFor(() => get(lean#LspStatus(), 'initialized', false)))
assert_true(getbufvar(source, 'lean_lsp_attached', false), 'recovery lost the first buffer')
assert_true(getbufvar(other, 'lean_lsp_attached', false), 'recovery lost the second buffer')

harness.Stop(rpc_log)
if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
delete(rpc_log)
qa!
