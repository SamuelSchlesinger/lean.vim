vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var rpc_log = root .. '/test-stale-imports-rpc.log'
delete(rpc_log)

execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  infoview: {autoopen: false},
  semantic_highlighting: {enable: false},
  lsp: {
    command: ['python3', root .. '/test/support/fake_lean_server.py', rpc_log],
    change_delay: 10,
    stderr: false,
  },
}

runtime plugin/lean.vim
filetype plugin indent on

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

def CountFor(method: string, name: string): number
  var count = 0
  for line in filereadable(rpc_log) ? readfile(rpc_log) : []
    var message = json_decode(line)
    if get(message, 'method', '') ==# method
        && get(get(get(message, 'params', {}), 'textDocument', {}), 'uri', '') =~# name
      count += 1
    endif
  endfor
  return count
enddef

# The server reports stale imports once; the plugin restarts the file
# automatically and the rebuilt imports come back clean.
execute 'edit ' .. fnameescape(root .. '/test/fixtures/StaleImportsFixed.lean')
assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'stale-imports fake server did not initialize')
var fixed_uri = lean#util#UriFromBuf(bufnr())
assert_true(WaitFor(() => CountFor('textDocument/didOpen', 'StaleImportsFixed') >= 2),
  'stale imports did not trigger an automatic file restart')
assert_equal(1, CountFor('textDocument/didClose', 'StaleImportsFixed'),
  'automatic restart did not close the document first')
assert_true(WaitFor(() => empty(lean#lsp#Diagnostics(fixed_uri))),
  'diagnostics did not clear after the automatic restart')

# A server that keeps reporting stale imports gets exactly one automatic
# restart, not a reopen loop.
execute 'edit ' .. fnameescape(root .. '/test/fixtures/StaleImportsBroken.lean')
var broken_uri = lean#util#UriFromBuf(bufnr())
assert_true(WaitFor(() => CountFor('textDocument/didOpen', 'StaleImportsBroken') >= 2),
  'persistently stale imports did not get their one automatic restart')
sleep 200m
assert_equal(2, CountFor('textDocument/didOpen', 'StaleImportsBroken'),
  'persistently stale imports kept restarting the file in a loop')
assert_false(empty(lean#lsp#Diagnostics(broken_uri)),
  'the stale-imports diagnostic was dropped while still applicable')

lean#Stop()
delete(rpc_log)

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
