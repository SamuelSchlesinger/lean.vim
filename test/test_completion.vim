vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var rpc_log = root .. '/test-completion-rpc.log'
delete(rpc_log)

execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  completion: {autotrigger: true},
  infoview: {autoopen: false},
  semantic_highlighting: {enable: false},
  lsp: {
    command: ['python3', root .. '/test/support/fake_lean_server.py', rpc_log],
    change_delay: 0,
    stderr: false,
  },
}

runtime plugin/lean.vim
filetype plugin indent on
execute 'edit! ' .. fnameescape(root .. '/test/fixtures/Completion.lean')

def WaitFor(Predicate: func(): any, timeout_ms: number = 3000): bool
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

def RpcMessages(method: string): list<any>
  var found: list<any> = []
  for encoded in filereadable(rpc_log) ? readfile(rpc_log) : []
    var message = json_decode(encoded)
    if get(message, 'method', '') ==# method
      add(found, message)
    endif
  endfor
  return found
enddef

def CompletionRequests(line: number = -1): list<any>
  return filter(RpcMessages('textDocument/completion'), (_, message) =>
    line < 0 || get(get(get(message, 'params', {}), 'position', {}), 'line', -1) == line)
enddef

assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'completion fake server did not initialize')
assert_equal('lean#completion#OmniFunc', &l:omnifunc, 'omnifunc was not installed')
assert_match('noinsert', &completeopt, 'completeopt was not applied buffer-locally')

# Insert-mode driver: feedkeys('x!') keeps insert mode alive processing
# timers, a poll timer reacts once the async pum arrives.
var pum_poll: dict<any> = {}
def PollPum(_timer: number)
  if pumvisible()
    pum_poll.fired = true
    feedkeys(pum_poll.keys, 'nt')
    if get(pum_poll, 'after', '') ==# 'resolve'
      timer_start(20, PollResolve)
    elseif get(pum_poll, 'after', '') ==# 'requery'
      timer_start(20, PollRequery)
    endif
    return
  endif
  pum_poll.waited += 10
  if pum_poll.waited > 3000
    feedkeys("\<Esc>", 'nt')
    return
  endif
  timer_start(10, PollPum)
enddef

def PollResolve(_timer: number)
  var info_id = popup_findinfo()
  if info_id > 0
    var text = join(getbufline(winbufnr(info_id), 1, '$'), "\n")
    if text =~# 'resolved documentation'
      pum_poll.popup_text = text
      feedkeys("\<C-y>\<Esc>", 'nt')
      return
    endif
  endif
  pum_poll.waited += 20
  if pum_poll.waited > 3000
    feedkeys("\<Esc>", 'nt')
    return
  endif
  timer_start(20, PollResolve)
enddef

def PollRequery(_timer: number)
  if len(CompletionRequests(5)) >= 2
    pum_poll.requeried = true
    feedkeys("\<Esc>", 'nt')
    return
  endif
  pum_poll.waited += 20
  if pum_poll.waited > 3000
    feedkeys("\<Esc>", 'nt')
    return
  endif
  timer_start(20, PollRequery)
enddef

def DriveInsert(typed: string, on_pum: string, after: string = '')
  pum_poll = {keys: on_pum, waited: 0, fired: false, after: after,
    popup_text: '', requeried: false}
  timer_start(10, PollPum)
  feedkeys(typed, 'xt!')
enddef

# 1. Manual omni completion honors a server textEdit that starts before the
# local word (`-- α😊abc`: edit begins at the α, UTF-16 unit 3, so accepting
# must also delete the α😊 prefix the edit covers).
DriveInsert("2G$a\<C-x>\<C-o>", "\<C-n>\<C-y>\<Esc>")
assert_true(pum_poll.fired, 'manual omni completion never opened the pum')
assert_equal('-- abcγδ', getline(2), 'reaching-back textEdit was not honored')

# 2. Auto-popup fires on typed identifier characters.
DriveInsert("1GA s", "\<C-n>\<C-y>\<Esc>")
assert_true(pum_poll.fired, 'auto-popup did not open after an identifier character')
assert_equal('def one := 1 succ', getline(1), 'auto completion inserted the wrong text')
var auto_requests = CompletionRequests(0)
assert_false(empty(auto_requests), 'no completion request was logged for line 0')
assert_equal(1, get(get(get(auto_requests[-1], 'params', {}), 'context', {}), 'triggerKind', -1),
  'typed identifier completion did not use triggerKind Invoked')

# 3. A typed dot triggers immediately with the trigger character context.
DriveInsert("3GA.", "\<C-n>\<C-y>\<Esc>")
assert_true(pum_poll.fired, 'auto-popup did not open after the dot trigger')
assert_equal('def two := 2.succ', getline(3), 'dot completion inserted the wrong text')
var dot_requests = CompletionRequests(2)
assert_false(empty(dot_requests), 'no completion request was logged for the dot line')
assert_equal(2, get(get(get(dot_requests[-1], 'params', {}), 'context', {}), 'triggerKind', -1),
  'dot completion did not use triggerKind TriggerCharacter')

# 4. Selecting an item resolves it once and fills the info popup.
DriveInsert("5GA s", "\<C-n>", 'resolve')
assert_true(pum_poll.fired, 'auto-popup did not open for the resolve test')
assert_match('resolved documentation', pum_poll.popup_text,
  'resolved documentation never reached the info popup')
var resolves = RpcMessages('completionItem/resolve')
assert_equal(1, len(resolves), 'selecting one item did not resolve exactly once')
assert_equal('succ', get(get(resolves[0], 'params', {}), 'label', ''),
  'the wrong item was resolved')
assert_equal('def four := 4 succ', getline(5), 'resolve test accepted the wrong item')

# 5. An isIncomplete list is re-queried when typing continues.
DriveInsert("6GA s", 'u', 'requery')
assert_true(pum_poll.fired, 'auto-popup did not open for the isIncomplete test')
assert_true(pum_poll.requeried, 'an isIncomplete list was not re-queried while typing')

# 6. A superseding request cancels the in-flight one (line 3 is slow).
var cancel_state = {typed: false}
def TypeSecondChar(_timer: number)
  cancel_state.typed = true
  feedkeys('u', 'nt')
  timer_start(20, PollCancel)
enddef
var cancel_poll = {waited: 0}
def PollCancel(_timer: number)
  if !empty(RpcMessages('$/cancelRequest'))
    feedkeys("\<Esc>", 'nt')
    return
  endif
  cancel_poll.waited += 20
  if cancel_poll.waited > 4000
    feedkeys("\<Esc>", 'nt')
    return
  endif
  timer_start(20, PollCancel)
enddef
timer_start(250, TypeSecondChar)
feedkeys("4GA s", 'xt!')
assert_true(cancel_state.typed, 'the superseding character was never typed')
assert_false(empty(RpcMessages('$/cancelRequest')),
  'superseding a slow completion request did not cancel it')

# 7. Abbreviations suppress completion entirely while active.
var completions_before = len(CompletionRequests())
feedkeys("Go\\alpha\<Tab>\<Esc>", 'xt')
assert_equal('α', getline(line('$')), 'abbreviation expansion broke with completion enabled')
sleep 300m
assert_equal(completions_before, len(CompletionRequests()),
  'completion requests were issued while an abbreviation was active')

lean#Stop()
sleep 50m

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
delete(rpc_log)
qa!
