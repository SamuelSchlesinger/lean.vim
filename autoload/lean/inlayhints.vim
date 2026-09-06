vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/requests.vim' as requests
import autoload 'lean/util.vim' as util

# LSP inlay hints rendered as text-property virtual text. Requests cover only
# the union of visible ranges (plus a margin): Lean elaborates hints lazily
# and Mathlib-sized files make whole-document requests wasteful.

var scopes: dict<any> = {}
var debounce_timers: dict<number> = {}
var pending_insert: dict<bool> = {}
var enabled_override = -1
var prop_types_initialized = false

const PROP_TYPES = ['LeanInlayHint', 'LeanInlayHintType', 'LeanInlayHintParam']

def Enabled(): bool
  if enabled_override >= 0
    return enabled_override == 1
  endif
  return config.Get().inlay_hints.enable
enddef

def EnsurePropTypes()
  if prop_types_initialized
    return
  endif
  prop_types_initialized = true
  highlight default link LeanInlayHint NonText
  highlight default link LeanInlayHintType LeanInlayHint
  highlight default link LeanInlayHintParam LeanInlayHint
  for name in PROP_TYPES
    if empty(prop_type_get(name))
      prop_type_add(name, {highlight: name})
    endif
  endfor
enddef

def ClearProps(bufnr: number)
  if !bufexists(bufnr)
    return
  endif
  for name in PROP_TYPES
    if !empty(prop_type_get(name))
      try
        prop_remove({type: name, all: true, bufnr: bufnr})
      catch
        # The buffer can vanish while a notification is in flight.
      endtry
    endif
  endfor
enddef

def SupportsHints(bufnr: number): bool
  var provider = get(lsp.Capabilities(bufnr), 'inlayHintProvider', v:null)
  if type(provider) == v:t_bool
    return provider
  endif
  return type(provider) == v:t_dict
enddef

export def Refresh(bufnr: number)
  if !Enabled() || !bufloaded(bufnr) || !SupportsHints(bufnr)
    return
  endif
  if bufnr == bufnr() && mode(1) =~# '^i'
      && !config.Get().inlay_hints.update_in_insert
    pending_insert[string(bufnr)] = true
    return
  endif
  lsp.Flush(bufnr)
  var spans = util.VisibleLineRanges(bufnr, max([0, config.Get().inlay_hints.margin]))
  if empty(spans)
    return
  endif
  EnsurePropTypes()
  var key = string(bufnr)
  if has_key(debounce_timers, key)
    timer_stop(remove(debounce_timers, key))
  endif
  if !has_key(scopes, key)
    scopes[key] = requests.NewScope()
  endif
  var context = requests.Begin(scopes[key], bufnr)
  var line_count = len(getbufline(bufnr, 1, '$'))
  var batch: dict<any> = {remaining: len(spans), hints: [], error: v:null}
  for span in spans
    # Vim closures share the for-loop variable; bind this request's range.
    var Reply = function(OnRangeHints,
      [bufnr, batch, span])
    var end_position: dict<number>
    if span[1] < line_count
      end_position = {line: span[1], character: 0}
    else
      var text = get(getbufline(bufnr, line_count), 0, '')
      end_position = {line: line_count - 1,
        character: max([0, utf16idx(text, strlen(text))])}
    endif
    requests.Send(context, 'textDocument/inlayHint', {
      textDocument: {uri: util.UriFromBuf(bufnr)},
      range: {start: {line: span[0] - 1, character: 0}, end: end_position},
    }, Reply)
  endfor
enddef

def OnRangeHints(bufnr: number, batch: dict<any>, span: list<number>, result: any, error: any)
  if type(error) == v:t_dict
    batch.error = error
  elseif type(result) == v:t_list
    for hint in result
      var position = type(hint) == v:t_dict ? get(hint, 'position', {}) : {}
      var line = type(position) == v:t_dict ? get(position, 'line', -1) : -1
      if type(line) == v:t_number && line >= span[0] - 1 && line < span[1]
        add(batch.hints, hint)
      endif
    endfor
  endif
  batch.remaining -= 1
  if batch.remaining == 0
    OnHints(bufnr, batch.hints, batch.error)
  endif
enddef

def HintLabel(label: any): string
  if type(label) == v:t_string
    return label
  endif
  if type(label) == v:t_list
    var parts: list<string> = []
    for part in label
      if type(part) == v:t_dict && type(get(part, 'value', v:null)) == v:t_string
        add(parts, part.value)
      endif
    endfor
    return join(parts, '')
  endif
  return ''
enddef

def OnHints(bufnr: number, result: any, error: any)
  var key = string(bufnr)
  if type(error) == v:t_dict
    # Keep what is rendered; the next sync or scroll refreshes.
    return
  endif
  if bufnr == bufnr() && mode(1) =~# '^i'
      && !config.Get().inlay_hints.update_in_insert
    pending_insert[key] = true
    return
  endif
  if type(result) != v:t_list
    ClearProps(bufnr)
    return
  endif
  ClearProps(bufnr)
  var lines = getbufline(bufnr, 1, '$')
  for hint in result
    if type(hint) != v:t_dict
      continue
    endif
    var position = get(hint, 'position', v:null)
    if type(position) != v:t_dict
        || type(get(position, 'line', v:null)) != v:t_number
        || type(get(position, 'character', v:null)) != v:t_number
        || position.line < 0 || position.line >= len(lines)
        || position.character < 0
      continue
    endif
    var label = HintLabel(get(hint, 'label', v:null))
    if empty(label)
      continue
    endif
    var text = lines[position.line]
    var byte_col = util.ByteColumn(text, position.character)
    if utf16idx(text, byte_col) != position.character
      continue
    endif
    if get(hint, 'paddingLeft', false) == true
      label = ' ' .. label
    endif
    if get(hint, 'paddingRight', false) == true
      label ..= ' '
    endif
    var kind = get(hint, 'kind', 0)
    var type_name = kind == 1 ? 'LeanInlayHintType'
      : kind == 2 ? 'LeanInlayHintParam'
      : 'LeanInlayHint'
    try
      prop_add(position.line + 1, byte_col + 1, {
        type: type_name,
        text: label,
        bufnr: bufnr,
      })
    catch
      # One stale position must not stop the rest of the batch.
    endtry
  endfor
enddef

def DebouncedRefresh(bufnr: number)
  var key = string(bufnr)
  if has_key(debounce_timers, key)
    remove(debounce_timers, key)
  endif
  Refresh(bufnr)
enddef

def ScheduleRefresh(bufnr: number)
  var key = string(bufnr)
  if has_key(debounce_timers, key)
    timer_stop(debounce_timers[key])
  endif
  debounce_timers[key] = timer_start(
    max([0, config.Get().inlay_hints.debounce]),
    (_) => DebouncedRefresh(bufnr))
enddef

# Called by the LSP layer whenever the server has the buffer's current text
# (didOpen and every didChange flush). Virtual text shifts the line under the
# cursor, so updates are deferred while inserting unless configured otherwise.
export def OnBufferSynced(bufnr: number)
  if !Enabled()
    return
  endif
  if bufnr == bufnr() && mode(1) =~# '^i'
      && !config.Get().inlay_hints.update_in_insert
    pending_insert[string(bufnr)] = true
    return
  endif
  ScheduleRefresh(bufnr)
enddef

export def OnInsertLeave(bufnr: number)
  if get(pending_insert, string(bufnr), false)
    remove(pending_insert, string(bufnr))
    if Enabled()
      ScheduleRefresh(bufnr)
    endif
  endif
enddef

export def OnWinScrolled()
  if !Enabled()
    return
  endif
  for key in keys(v:event)
    if key ==# 'all'
      continue
    endif
    var bufnr = winbufnr(str2nr(key))
    if bufnr > 0 && getbufvar(bufnr, '&filetype') ==# 'lean'
        && getbufvar(bufnr, 'lean_lsp_attached', false)
      ScheduleRefresh(bufnr)
    endif
  endfor
enddef

export def Clear(bufnr: number)
  var key = string(bufnr)
  if has_key(debounce_timers, key)
    timer_stop(remove(debounce_timers, key))
  endif
  if has_key(pending_insert, key)
    remove(pending_insert, key)
  endif
  if has_key(scopes, key)
    requests.Cancel(remove(scopes, key))
  endif
  ClearProps(bufnr)
enddef

export def Toggle()
  var target = !Enabled()
  enabled_override = target ? 1 : 0
  for info in getbufinfo({bufloaded: true})
    if getbufvar(info.bufnr, '&filetype') ==# 'lean'
        && getbufvar(info.bufnr, 'lean_lsp_attached', false)
      if target
        Refresh(info.bufnr)
      else
        Clear(info.bufnr)
      endif
    endif
  endfor
  util.Notify(target ? 'inlay hints enabled' : 'inlay hints disabled', 'ModeMsg')
enddef

defcompile
