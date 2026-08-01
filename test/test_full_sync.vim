vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var rpc_log = root .. '/test-full-sync-rpc.log'
delete(rpc_log)

execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  infoview: {autoopen: false},
  semantic_highlighting: {enable: false},
  lsp: {
    command: ['python3', root .. '/test/support/fake_lean_server.py', rpc_log, '1'],
    change_delay: 10,
    stderr: false,
  },
}

runtime plugin/lean.vim
filetype plugin indent on
execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')

def WaitFor(Predicate: func(): any, timeout_ms: number = 2000): bool
  var elapsed = 0
  while elapsed < timeout_ms
    if Predicate()
      return true
    endif
    sleep 10m
    elapsed += 10
  endwhile
  return Predicate()
enddef

assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'full-sync fake server did not initialize')
var source = bufnr()
var previous_version = getbufvar(source, 'lean_lsp_version', 0)
setline(2, '  exact 43')
lean#OnChanged(source)
assert_true(WaitFor(() => getbufvar(source, 'lean_lsp_version', 0) > previous_version),
  'full-sync document change was not flushed')
var expected_text = lean#util#BufText(source)
sleep 20m
lean#Stop()

var messages = mapnew(filereadable(rpc_log) ? readfile(rpc_log) : [],
  (_, line) => json_decode(line))
var changes = filter(messages, (_, message) =>
  get(message, 'method', '') ==# 'textDocument/didChange')
assert_true(!empty(changes), 'full-sync server did not receive didChange')
assert_false(has_key(changes[-1].params.contentChanges[0], 'range'),
  'full-sync server received an incremental range')
assert_equal(expected_text, changes[-1].params.contentChanges[0].text,
  'full-sync fallback did not send the current document')
delete(rpc_log)

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
