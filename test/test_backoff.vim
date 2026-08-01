vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  infoview: {autoopen: false},
  lsp: {
    command: [root .. '/test/support/nonexistent-lean-binary'],
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

# A missing binary fails asynchronously on Unix: job_start() succeeds and the
# exec failure arrives through the exit callback. Each attempt reports one
# anchored "exited" line; the derived initialization-failure line is ignored.
def FailureCount(): number
  return len(filter(split(execute('messages'), "\n"), (_, line) =>
    line =~# '^\[lean\.vim\] \%(cannot start Lean language server\|language server exited\)'))
enddef

execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')
assert_true(WaitFor(() => FailureCount() == 1),
  'opening the buffer did not report the start failure')
assert_true(WaitFor(() => !get(lean#LspStatus(), 'running', true)),
  'server reported running after a failed start')

# Re-attaching (what every WinEnter does) must not spawn or notify again
# while the failure backoff is active.
for _ in range(5)
  lean#OnBufWinEnter(bufnr())
endfor
sleep 100m
assert_equal(1, FailureCount(), 'window re-entry retried a failed server inside the backoff')

# A manual restart clears the backoff and retries immediately.
lean#RestartServer()
assert_true(WaitFor(() => FailureCount() >= 2),
  ':LeanRestartServer did not retry inside the backoff')
assert_true(WaitFor(() => !get(lean#LspStatus(), 'running', true)),
  'server reported running after the manual retry failed')
var after_restart = FailureCount()

# The manual retry failed again, so automatic attaches stay quiet once more.
lean#OnBufWinEnter(bufnr())
sleep 100m
assert_equal(after_restart, FailureCount(),
  'window re-entry retried again after the manual restart failed')

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
