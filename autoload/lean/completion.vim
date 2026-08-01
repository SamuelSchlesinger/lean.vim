vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/util.vim' as util

# Asynchronous LSP completion. The omnifunc's second call issues the request
# and returns v:none — the pattern :h complete-functions documents for
# asynchronous completion — and the reply is shown later with complete().
# Lean elaboration can block replies for seconds, so nothing here ever waits.
# The as-you-type popup shares the same request/show path.

var generation = 0
var session: dict<any> = {}
var pending_trigger = ''
var debounce_timer = -1
var timeout_timer = -1
var resolve_state: dict<any> = {request_id: -1, timer: -1, index: -1}

# LSP CompletionItemKind → single-letter pum kind. Lean reports theorems as
# kind 23 (Event), so 23 maps to 't'.
const KIND_LETTERS = {
  1: 'w', 2: 'm', 3: 'f', 4: 'c', 5: 'F', 6: 'v', 7: 'C', 8: 'I', 9: 'M',
  10: 'p', 11: 'u', 12: 'l', 13: 'E', 14: 'k', 15: 's', 16: 'r', 17: 'P',
  18: 'R', 19: 'D', 20: 'e', 21: 'n', 22: 'S', 23: 't', 24: 'O', 25: 'T',
}

def Enabled(bufnr: number): bool
  return config.Get().completion.enable
    && getbufvar(bufnr, '&filetype') ==# 'lean'
enddef

# Vim 9.2's built-in 'autocomplete' drives completion itself; two popups
# fighting over the pum helps nobody. eval() keeps this compiling on builds
# without the option.
def BuiltinAutocompleteActive(): bool
  return exists('+autocomplete') && !empty(eval('&autocomplete'))
enddef

# 0-based byte offset where the completion base begins, given the 0-based
# cursor byte offset. A French quote joins the base so «...» names complete
# as one unit.
def WordStart(line: string, cursor: number): number
  var start = match(strpart(line, 0, cursor), '\k*$')
  if start >= 2 && strpart(line, start - 2, 2) ==# '«'
    return start - 2
  endif
  return start
enddef

def StopTimer(name: string)
  if name ==# 'debounce' && debounce_timer >= 0
    timer_stop(debounce_timer)
    debounce_timer = -1
  elseif name ==# 'timeout' && timeout_timer >= 0
    timer_stop(timeout_timer)
    timeout_timer = -1
  endif
enddef

def CancelResolve()
  if resolve_state.timer >= 0
    timer_stop(resolve_state.timer)
    resolve_state.timer = -1
  endif
  if resolve_state.request_id > 0 && !empty(session)
    lsp.Cancel(session.bufnr, resolve_state.request_id)
  endif
  resolve_state.request_id = -1
  resolve_state.index = -1
enddef

def CancelInflight()
  StopTimer('debounce')
  StopTimer('timeout')
  CancelResolve()
  if !empty(session) && get(session, 'request_id', -1) > 0
    lsp.Cancel(session.bufnr, session.request_id)
    session.request_id = -1
  endif
enddef

def Reset()
  CancelInflight()
  session = {}
enddef

export def OmniFunc(findstart: number, base: string): any
  var bufnr = bufnr()
  if findstart == 1
    if !Enabled(bufnr) || getbufvar(bufnr, 'lean_abbrev_active', false)
      return -3
    endif
    return WordStart(getline('.'), col('.') - 1)
  endif
  # During this call Vim parks the cursor at the start column; issuing the
  # request now would capture that position. Defer until the call returns.
  timer_start(0, (_) => Start(bufnr, 'manual'))
  return v:none
enddef

def Start(bufnr: number, source: string)
  CancelInflight()
  if !Enabled(bufnr) || bufnr != bufnr() || mode(1) !~# '^i'
      || getbufvar(bufnr, 'lean_abbrev_active', false)
    return
  endif
  if type(get(lsp.Capabilities(bufnr), 'completionProvider', v:null)) != v:t_dict
    return
  endif
  lsp.Flush(bufnr)
  generation += 1
  var request_generation = generation
  var params = util.PositionParams(bufnr)
  if source ==# 'dot'
    params.context = {triggerKind: 2, triggerCharacter: '.'}
  elseif source ==# 'refresh'
    params.context = {triggerKind: 3}
  else
    params.context = {triggerKind: 1}
  endif
  session = {
    bufnr: bufnr,
    generation: request_generation,
    source: source,
    lnum: line('.'),
    col: col('.'),
    tick: b:changedtick,
    request_id: -1,
    items: [],
    item_defaults: {},
    is_incomplete: false,
    shown: false,
  }
  session.request_id = lsp.Request(bufnr, 'textDocument/completion', params,
    (result, error) => OnResult(request_generation, result, error))
  timeout_timer = timer_start(max([1, config.Get().completion.timeout]),
    (_) => CancelTimedOut(bufnr, request_generation))
enddef

def CancelTimedOut(bufnr: number, request_generation: number)
  timeout_timer = -1
  if !empty(session) && session.generation == request_generation
      && session.request_id > 0
    lsp.Cancel(bufnr, session.request_id)
    session.request_id = -1
  endif
enddef

def OnResult(request_generation: number, result: any, error: any)
  if empty(session) || session.generation != request_generation
    return
  endif
  session.request_id = -1
  StopTimer('timeout')
  if type(error) == v:t_dict
    return
  endif
  var items: list<any> = []
  if type(result) == v:t_list
    items = result
  elseif type(result) == v:t_dict
    var list_items = get(result, 'items', [])
    items = type(list_items) == v:t_list ? list_items : []
    session.is_incomplete = get(result, 'isIncomplete', false) == true
    var defaults = get(result, 'itemDefaults', {})
    session.item_defaults = type(defaults) == v:t_dict ? defaults : {}
  endif
  session.items = filter(copy(items), (_, item) => type(item) == v:t_dict)
  # complete() may not run under the textlock of a channel callback; a
  # zero-delay timer provides a safe context.
  timer_start(0, (_) => Show(request_generation))
enddef

def Show(request_generation: number)
  if empty(session) || session.generation != request_generation
      || empty(session.items)
    return
  endif
  var bufnr = session.bufnr
  if bufnr != bufnr() || mode(1) !~# '^i'
      || getbufvar(bufnr, 'lean_abbrev_active', false)
    return
  endif
  if b:changedtick != session.tick || line('.') != session.lnum
      || col('.') != session.col
    return
  endif
  var startcol = StartColumn()
  if startcol <= 0 || startcol > session.col
    return
  endif
  var vim_items: list<any> = []
  for index in SortedItemIndexes()
    add(vim_items, MapItem(session.items[index], index))
  endfor
  session.shown = true
  complete(startcol, vim_items)
enddef

def SortKey(item: dict<any>): string
  var text = get(item, 'sortText', v:null)
  if type(text) == v:t_string && !empty(text)
    return text
  endif
  var label = get(item, 'label', '')
  return type(label) == v:t_string ? label : ''
enddef

def CompareSortKeys(left: number, right: number): number
  var left_key = SortKey(session.items[left])
  var right_key = SortKey(session.items[right])
  if left_key ==# right_key
    return left - right
  endif
  return left_key <# right_key ? -1 : 1
enddef

# Display order honors sortText; user_data keeps the original index so
# resolve still addresses the raw server item.
def SortedItemIndexes(): list<number>
  var indexes = range(len(session.items))
  sort(indexes, CompareSortKeys)
  return indexes
enddef

# Accepts a plain Range, a TextEdit ({range}), an InsertReplaceEdit
# ({insert, replace}), or itemDefaults.editRange in either form.
def NormalizedRange(container: any): any
  if type(container) != v:t_dict
    return v:null
  endif
  if has_key(container, 'start')
    return container
  endif
  if type(get(container, 'range', v:null)) == v:t_dict
    return container.range
  endif
  return get(container, 'insert', v:null)
enddef

def EditRangeStart(container: any): number
  var normalized = NormalizedRange(container)
  if type(normalized) != v:t_dict
      || type(get(normalized, 'start', v:null)) != v:t_dict
    return -1
  endif
  var start = normalized.start
  if type(get(start, 'line', v:null)) != v:t_number
      || type(get(start, 'character', v:null)) != v:t_number
      || start.character < 0 || start.line != session.lnum - 1
    return -1
  endif
  return start.character
enddef

# UTF-16 start character shared by every textEdit in the reply, or -1 when
# absent or inconsistent; complete() only has one start column.
def TextEditStartCharacter(): number
  var start = EditRangeStart(get(session.item_defaults, 'editRange', v:null))
  for item in session.items
    var edit = get(item, 'textEdit', v:null)
    if type(edit) != v:t_dict
      continue
    endif
    var item_start = EditRangeStart(edit)
    if item_start < 0 || (start >= 0 && item_start != start)
      return -1
    endif
    start = item_start
  endfor
  return start
enddef

# 1-based byte column for complete(). Vim's popup filters items against the
# text after the start column, so the column never moves before the local
# word start: a uniform server textEdit beginning inside the word narrows the
# column, while one reaching further back is honored after acceptance by
# deleting the covered prefix (see FixupAcceptedEdit).
def StartColumn(): number
  session.accept_delete = []
  var line = getline(session.lnum)
  var cursor = session.col - 1
  var word_start = WordStart(line, cursor)
  var edit_start = TextEditStartCharacter()
  if edit_start < 0
    return word_start + 1
  endif
  var byte_col = util.ByteColumn(line, edit_start)
  if byte_col > cursor || utf16idx(line, byte_col) != edit_start
    return word_start + 1
  endif
  if byte_col >= word_start
    return byte_col + 1
  endif
  session.accept_delete = [byte_col, word_start]
  return word_start + 1
enddef

# Vim inserted the item at the word start; a textEdit that began earlier also
# covers the bytes before it, which must go so the edit is not applied twice.
def FixupAcceptedEdit()
  var deletion: list<number> = get(session, 'accept_delete', [])
  if len(deletion) != 2 || session.bufnr != bufnr()
    return
  endif
  var completed = get(v:completed_item, 'user_data', v:null)
  if type(completed) != v:t_dict
      || get(completed, 'lean_completion_index', -1) < 0
    return
  endif
  var line = getline(session.lnum)
  if deletion[1] > strlen(line)
    return
  endif
  try
    undojoin
  catch /E790:/
  endtry
  setline(session.lnum, strpart(line, 0, deletion[0]) .. strpart(line, deletion[1]))
  if line('.') == session.lnum
    cursor(session.lnum, max([1, col('.') - (deletion[1] - deletion[0])]))
  endif
enddef

def DocumentationText(documentation: any): string
  if type(documentation) == v:t_string
    return documentation
  endif
  if type(documentation) == v:t_dict
    var value = get(documentation, 'value', '')
    if type(value) == v:t_string
      return join(util.MarkdownLines(value), "\n")
    endif
  endif
  return ''
enddef

def MapItem(item: dict<any>, index: number): dict<any>
  var label = get(item, 'label', '')
  if type(label) != v:t_string
    label = string(label)
  endif
  var word = label
  var edit = get(item, 'textEdit', v:null)
  if type(edit) == v:t_dict
      && type(get(edit, 'newText', v:null)) == v:t_string
    word = edit.newText
  elseif type(get(item, 'insertText', v:null)) == v:t_string
    word = item.insertText
  endif
  var detail = get(item, 'detail', '')
  if type(detail) != v:t_string
    detail = ''
  endif
  var menu = ''
  if !empty(detail)
    menu = split(detail, "\n", true)[0]
    if strchars(menu) > 60
      menu = strcharpart(menu, 0, 59) .. '…'
    endif
  endif
  var info = DocumentationText(get(item, 'documentation', v:null))
  if empty(info)
    # Give the info popup initial content so an async resolve has a popup to
    # update; Vim only creates one for items with info text.
    info = detail
  endif
  var kind = get(item, 'kind', 0)
  return {
    word: word,
    abbr: label,
    kind: type(kind) == v:t_number ? get(KIND_LETTERS, kind, '') : '',
    menu: menu,
    info: info,
    dup: 1,
    icase: 0,
    user_data: {lean_completion_index: index},
  }
enddef

def Debounce(bufnr: number, source: string, delay: number)
  StopTimer('debounce')
  if delay <= 0
    Start(bufnr, source)
    return
  endif
  debounce_timer = timer_start(delay, (_) => DebouncedStart(bufnr, source))
enddef

def DebouncedStart(bufnr: number, source: string)
  debounce_timer = -1
  Start(bufnr, source)
enddef

def OnInsertCharPre()
  var bufnr = bufnr()
  if !Enabled(bufnr) || BuiltinAutocompleteActive()
    return
  endif
  # The abbreviation handler runs first by registration order; it may also
  # blank v:char for an escaped leader.
  if getbufvar(bufnr, 'lean_abbrev_active', false) || empty(v:char)
    pending_trigger = ''
    return
  endif
  if v:char ==# '.'
    pending_trigger = 'dot'
  elseif v:char =~# '^\k$'
    pending_trigger = 'word'
  else
    pending_trigger = ''
    CancelInflight()
  endif
enddef

def OnTextChangedI(bufnr: number)
  var trigger = pending_trigger
  pending_trigger = ''
  if empty(trigger) || !Enabled(bufnr) || BuiltinAutocompleteActive()
      || getbufvar(bufnr, 'lean_abbrev_active', false)
    return
  endif
  if trigger ==# 'dot'
    Debounce(bufnr, 'dot', 0)
    return
  endif
  var line = getline('.')
  var cursor = col('.') - 1
  var start = WordStart(line, cursor)
  if strchars(strpart(line, start, cursor - start))
      < config.Get().completion.min_length
    return
  endif
  Debounce(bufnr, 'auto', config.Get().completion.debounce)
enddef

def OnTextChangedP(bufnr: number)
  var trigger = pending_trigger
  pending_trigger = ''
  if empty(trigger) || !Enabled(bufnr)
    return
  endif
  # Narrowing a complete list is native pum filtering; only an isIncomplete
  # reply warrants asking the server again.
  if !empty(session) && get(session, 'shown', false)
      && get(session, 'is_incomplete', false)
    Debounce(bufnr, 'refresh', config.Get().completion.debounce)
  endif
enddef

def OnCompleteChangedEvent(bufnr: number)
  if !config.Get().completion.resolve || !Enabled(bufnr)
    return
  endif
  CancelResolve()
  var completed = get(v:event, 'completed_item', {})
  var user_data = type(completed) == v:t_dict
    ? get(completed, 'user_data', v:null)
    : v:null
  if type(user_data) != v:t_dict
    return
  endif
  var index = get(user_data, 'lean_completion_index', -1)
  if index < 0 || empty(session) || index >= len(session.items)
    return
  endif
  if !empty(DocumentationText(get(session.items[index], 'documentation', v:null)))
    return
  endif
  var provider = get(lsp.Capabilities(bufnr), 'completionProvider', {})
  if type(provider) != v:t_dict
      || get(provider, 'resolveProvider', false) != true
    return
  endif
  # Debounce so holding <C-n> issues at most one in-flight resolve.
  resolve_state.timer = timer_start(100, (_) => RequestResolve(bufnr, index))
enddef

def RequestResolve(bufnr: number, index: number)
  resolve_state.timer = -1
  if empty(session) || !get(session, 'shown', false)
      || index >= len(session.items) || mode(1) !~# '^i'
    return
  endif
  var request_generation = session.generation
  resolve_state.index = index
  resolve_state.request_id = lsp.Request(bufnr, 'completionItem/resolve',
    deepcopy(session.items[index]),
    (result, error) => OnResolved(request_generation, index, result, error))
enddef

def OnResolved(request_generation: number, index: number, result: any, error: any)
  resolve_state.request_id = -1
  if empty(session) || session.generation != request_generation
      || type(error) == v:t_dict || type(result) != v:t_dict
    return
  endif
  if index < len(session.items)
    # Cache: re-selecting this item reuses the resolved copy.
    session.items[index] = result
  endif
  var text = DocumentationText(get(result, 'documentation', v:null))
  if empty(text)
    var detail = get(result, 'detail', '')
    text = type(detail) == v:t_string ? detail : ''
  endif
  if empty(text) || !get(session, 'shown', false)
    return
  endif
  # Only touch the popup while the same item is still selected.
  var info = complete_info(['selected', 'items'])
  var selected = get(info, 'selected', -1)
  if selected < 0 || selected >= len(get(info, 'items', []))
    return
  endif
  var selected_data = get(info.items[selected], 'user_data', v:null)
  if type(selected_data) != v:t_dict
      || get(selected_data, 'lean_completion_index', -1) != index
    return
  endif
  var popup_id = popup_findinfo()
  if popup_id <= 0
    return
  endif
  popup_settext(popup_id, split(text, "\n", true))
  popup_show(popup_id)
enddef

def OnCompleteDoneEvent()
  CancelResolve()
  if empty(session)
    return
  endif
  if get(session, 'shown', false)
    FixupAcceptedEdit()
  endif
  session.shown = false
  session.accept_delete = []
enddef

def OnInsertLeaveEvent()
  pending_trigger = ''
  Reset()
enddef

export def SetupBuffer(bufnr: number)
  if !config.Get().completion.enable
    return
  endif
  setbufvar(bufnr, '&omnifunc', 'lean#completion#OmniFunc')
  if config.Get().completion.set_completeopt
    setbufvar(bufnr, '&completeopt', 'menuone,noinsert,noselect,popup')
  endif
  if !config.Get().completion.autotrigger
    return
  endif
  var group = $'lean_completion_{bufnr}'
  execute $'augroup {group}'
  autocmd!
  execute $'autocmd InsertCharPre <buffer={bufnr}> call lean#completion#InsertCharPre()'
  execute $'autocmd TextChangedI <buffer={bufnr}> call lean#completion#TextChangedI({bufnr})'
  execute $'autocmd TextChangedP <buffer={bufnr}> call lean#completion#TextChangedP({bufnr})'
  execute $'autocmd CompleteChanged <buffer={bufnr}> call lean#completion#CompleteChanged({bufnr})'
  execute $'autocmd CompleteDone <buffer={bufnr}> call lean#completion#CompleteDone()'
  execute $'autocmd InsertLeave,BufLeave <buffer={bufnr}> call lean#completion#InsertLeave()'
  augroup END
enddef

export def TeardownBuffer(bufnr: number)
  if !empty(session) && get(session, 'bufnr', -1) == bufnr
    Reset()
  endif
  pending_trigger = ''
  var group = $'lean_completion_{bufnr}'
  execute $'augroup {group}'
  autocmd!
  augroup END
  if bufexists(bufnr)
      && getbufvar(bufnr, '&omnifunc', '') ==# 'lean#completion#OmniFunc'
    setbufvar(bufnr, '&omnifunc', '')
  endif
  # 'completeopt' is global-local; only the current buffer can drop its local
  # value back to the global one.
  if bufnr == bufnr() && config.Get().completion.set_completeopt
    setlocal completeopt<
  endif
enddef

# Legacy-callable exported wrappers for the buffer autocommands, which run
# outside this script's Vim9 context.
export def InsertCharPre()
  OnInsertCharPre()
enddef

export def TextChangedI(bufnr: number)
  OnTextChangedI(bufnr)
enddef

export def TextChangedP(bufnr: number)
  OnTextChangedP(bufnr)
enddef

export def CompleteChanged(bufnr: number)
  OnCompleteChangedEvent(bufnr)
enddef

export def CompleteDone()
  OnCompleteDoneEvent()
enddef

export def InsertLeave()
  OnInsertLeaveEvent()
enddef

defcompile
