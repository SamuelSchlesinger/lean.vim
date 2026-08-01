vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var rpc_log = root .. '/test-progress-rpc.log'
var fixture = root .. '/test-progress-fixture-Progress.lean'
delete(rpc_log)
writefile(['-- filler line']->repeat(3000), fixture)

execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  infoview: {autoopen: false},
  completion: {autotrigger: false},
  inlay_hints: {enable: false},
  semantic_highlighting: {links: {variable: 'Identifier'}},
  lsp: {
    command: ['python3', root .. '/test/support/fake_lean_server.py', rpc_log],
    change_delay: 0,
    stderr: false,
  },
}

runtime plugin/lean.vim
filetype plugin indent on
execute 'edit! ' .. fnameescape(fixture)

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

def ProgressSigns(): list<any>
  var placed = sign_getplaced(bufnr(), {group: 'lean-progress'})
  return empty(placed) ? [] : placed[0].signs
enddef

assert_true(WaitFor(() => get(lean#LspStatus(), 'initialized', false)),
  'progress fake server did not initialize')

# semantic_highlighting.links re-enables a token type that is quiet by
# default, without enabling the others.
assert_true(!empty(prop_type_get('LeanSemantic_variable')),
  'semantic_highlighting.links did not re-enable variable tokens')
assert_true(empty(prop_type_get('LeanSemantic_property')),
  'a links override enabled unrelated token types')

# The server reports the whole 3000-line file as processing; only the
# visible span (plus a 20-line margin) may receive signs.
assert_true(WaitFor(() => !empty(ProgressSigns())), 'no progress signs were placed')
assert_true(lean#lsp#ProgressAt(bufnr(), 2500),
  'progress data should still cover the whole file')
var window_info = getwininfo(win_getid())[0]
var span_first = max([1, window_info.topline - 20])
var span_last = min([3000, window_info.botline + 20])
var lnums = mapnew(ProgressSigns(), (_, sign) => sign.lnum)
assert_true(len(lnums) <= span_last - span_first + 1,
  $'whole-file progress placed {len(lnums)} signs for a '
  .. $'{span_last - span_first + 1}-line visible span')
assert_true(min(lnums) >= span_first && max(lnums) <= span_last,
  $'progress signs {min(lnums)}..{max(lnums)} escaped the visible span '
  .. $'{span_first}..{span_last}')

# Moving the view re-renders the decorated span around it. The poll pauses
# longer than the 100ms render debounce, which restarts on every call.
cursor(1500, 1)
normal! zz
var rerendered = false
for _ in range(10)
  lean#OnWinScrolled()
  sleep 300m
  if indexof(ProgressSigns(), (_, sign) => sign.lnum == line('.')) >= 0
    rerendered = true
    break
  endif
endfor
assert_true(rerendered, 'scrolling did not re-render progress signs around the new view')

# A semantic-token edit burst coalesces into few requests.
def SemanticRequestCount(): number
  var count = 0
  for encoded in filereadable(rpc_log) ? readfile(rpc_log) : []
    if get(json_decode(encoded), 'method', '') ==# 'textDocument/semanticTokens/full'
      count += 1
    endif
  endfor
  return count
enddef

sleep 300m
var semantic_before = SemanticRequestCount()
for index in range(5)
  setline(1, $'-- edited {index}')
  doautocmd TextChanged
endfor
sleep 600m
var semantic_after = SemanticRequestCount()
assert_true(semantic_after - semantic_before <= 2,
  $'an edit burst issued {semantic_after - semantic_before} semantic-token requests')

lean#Stop()
sleep 50m

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  delete(fixture)
  cquit
endif
delete(rpc_log)
delete(fixture)
qa!
