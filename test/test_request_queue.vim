vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var rpc_log = root .. '/test-request-queue-rpc.log'
delete(rpc_log)

execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  infoview: {autoopen: false, update_cooldown: 0},
  semantic_highlighting: {enable: false},
  lsp: {
    command: [
      'python3', root .. '/test/support/fake_lean_server.py', rpc_log, '2', '1.0', '0',
    ],
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

# These updates all happen while initialize is still in flight. Superseded
# requests should be removed from the local queue, not flushed in a burst when
# the server becomes ready.
lean#InfoviewOpen()
noautocmd call cursor(2, 1)
lean#OnCursorMoved(bufnr())
noautocmd call cursor(3, 1)
lean#OnCursorMoved(bufnr())
noautocmd call cursor(4, 1)
lean#OnCursorMoved(bufnr())

assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'delayed fake server did not initialize')
assert_true(WaitFor(() => !empty(get(lean#InfoviewState(), 'goal', []))),
  'latest queued infoview request did not complete')
lean#Stop()
sleep 50m

var messages = mapnew(filereadable(rpc_log) ? readfile(rpc_log) : [],
  (_, line) => json_decode(line))
assert_equal(1, len(filter(copy(messages), (_, message) =>
  get(message, 'method', '') ==# '$/lean/plainGoal')),
  'superseded goal requests were flushed after initialization')
assert_equal(1, len(filter(copy(messages), (_, message) =>
  get(message, 'method', '') ==# '$/lean/plainTermGoal')),
  'superseded term-goal requests were flushed after initialization')

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
delete(rpc_log)
qa!
