vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
import './support/harness.vim' as harness
var attempts = 0
var exit_on_start = false
def ServerCommand(_root: string): list<string>
  attempts += 1
  if exit_on_start
    return ['python3', '-c', 'raise SystemExit(1)']
  endif
  return [root .. '/test/support/nonexistent-lean-binary']
enddef
g:lean_config = {
  infoview: {autoopen: false},
  lsp: {
    command: ServerCommand,
    stderr: false,
  },
}

runtime plugin/lean.vim
filetype plugin indent on


# Count actual attempts separately from notifications: duplicate failure
# messages must not be mistaken for a broken restart backoff.
def FailureCount(): number
  return len(filter(split(execute('messages'), "\n"), (_, line) =>
    line =~# '^\[lean\.vim\] \%(cannot start Lean language server\|language server exited\)'))
enddef

execute 'edit ' .. fnameescape(root .. '/test/fixtures/Basic.lean')
assert_true(harness.WaitFor(() => FailureCount() == 1),
  'opening the buffer did not report the start failure')
assert_true(harness.WaitFor(() => !get(lean#LspStatus(), 'running', true)),
  'server reported running after a failed start')
assert_equal(1, attempts)
assert_match('executable not found', execute('messages'))

# Re-attaching (what every WinEnter does) must not spawn or notify again
# while the failure backoff is active.
for _ in range(5)
  lean#OnBufWinEnter(bufnr())
endfor
sleep 100m
assert_equal(1, FailureCount(), 'window re-entry retried a failed server inside the backoff')
assert_equal(1, attempts, 'window re-entry attempted another server start')

# A manual restart clears the backoff and retries immediately.
lean#RestartServer()
assert_true(harness.WaitFor(() => FailureCount() >= 2),
  ':LeanRestartServer did not retry inside the backoff')
assert_true(harness.WaitFor(() => !get(lean#LspStatus(), 'running', true)),
  'server reported running after the manual retry failed')
var after_restart = FailureCount()
assert_equal(2, attempts, 'manual restart did not make exactly one new attempt')
assert_equal(2, after_restart, 'each failed start must report one error')

# The manual retry failed again, so automatic attaches stay quiet once more.
lean#OnBufWinEnter(bufnr())
sleep 100m
assert_equal(after_restart, FailureCount(),
  'window re-entry retried again after the manual restart failed')
assert_equal(2, attempts)

# An executable may also exit before reading initialize (for example, an
# elan shim with an unavailable toolchain). No delayed channel-write error
# should escape into the editor after its single exit notification.
exit_on_start = true
lean#RestartServer()
assert_true(harness.WaitFor(() => !get(lean#LspStatus(), 'running', true)))
sleep 100m
assert_equal(3, attempts)
assert_equal(3, FailureCount(), 'an early process exit reported more than one failure')
lean#OnBufWinEnter(bufnr())
assert_equal(3, attempts, 'an early process exit bypassed restart backoff')

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
