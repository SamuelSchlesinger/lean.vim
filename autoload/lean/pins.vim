vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/requests.vim' as requests
import autoload 'lean/infoview_render.vim' as renderer
import autoload 'lean/util.vim' as util

# Live anchors use native text properties for ordinary edits. setline() and
# programmatic buffer replacements discard properties, so those changes are
# rebased through the old/new text before the anchor is recreated.
const PROPERTY = 'LeanLivePin'
var buffers: dict<any> = {}
var next_id = 1
var OnChanged: any = v:null

export def SetChangedHandler(Handler: func(number))
  OnChanged = Handler
enddef

def Place(pin: dict<any>)
  var lines = getbufline(pin.bufnr, 1, '$')
  pin.line = min([max([0, pin.line]), len(lines) - 1])
  var column = util.ByteColumn(lines[pin.line], pin.character)
  pin.character = max([0, utf16idx(lines[pin.line], column)])
  prop_add(pin.line + 1, column + 1,
    {bufnr: pin.bufnr, type: PROPERTY, id: pin.id, length: 0})
enddef

def PositionAt(text: string, offset: number): dict<number>
  var prefix = strpart(text, 0, offset)
  var line = count(prefix, "\n")
  var tail = strpart(prefix, strridx(prefix, "\n") + 1)
  return {line: line, character: max([0, utf16idx(tail, strlen(tail))])}
enddef

def NotifyChanged(bufnr: number)
  var state = get(buffers, string(bufnr), {})
  if empty(state)
    return
  endif
  state.timer = -1
  if type(OnChanged) == v:t_func
    OnChanged(bufnr)
  endif
enddef

def Track(bufnr: number)
  var state = get(buffers, string(bufnr), {})
  if empty(state) || !bufloaded(bufnr)
    return
  endif
  var text = util.BufText(bufnr)
  var change = util.IncrementalChange(state.text, text)
  var start = util.TextOffset(state.text, change.range.start)
  var finish = util.TextOffset(state.text, change.range.end)
  for pin in state.pins
    var property = prop_find({bufnr: bufnr, type: PROPERTY, id: pin.id,
      both: true, lnum: 1, col: 1}, 'f')
    if !empty(property)
      pin.line = property.lnum - 1
      pin.character = max([0, utf16idx(getbufline(bufnr, property.lnum)[0], property.col - 1)])
    elseif text !=# state.text
      var offset = util.TextOffset(state.text, {line: pin.line, character: pin.character})
      # Right gravity: inserted text at the anchor stays before the pin. A
      # removed position collapses to the end of its replacement.
      if offset >= finish
        offset += strlen(change.text) - (finish - start)
      elseif offset >= start
        offset = start + strlen(change.text)
      endif
      extend(pin, PositionAt(text, min([strlen(text), max([0, offset])])))
      Place(pin)
    else
      Place(pin)
    endif
    pin.uri = util.UriFromBuf(bufnr)
    pin.dirty = true
    requests.Cancel(pin.scope)
  endfor
  state.text = text
enddef

def OnLines(bufnr: number, _start: number, _end: number, _added: number, _changes: list<any>)
  Track(bufnr)
  var state = get(buffers, string(bufnr), {})
  if !empty(state) && state.timer < 0
    state.timer = timer_start(0, (_) => NotifyChanged(bufnr))
  endif
enddef

def EnsureLoaded(bufnr: number)
  var state = buffers[string(bufnr)]
  if state.listener < 0 && bufloaded(bufnr)
    Track(bufnr)
    state.listener = listener_add(OnLines, bufnr)
  endif
enddef

export def New(bufnr: number, position: dict<number>): dict<any>
  if empty(prop_type_get(PROPERTY))
    prop_type_add(PROPERTY, {start_incl: false, end_incl: false})
  endif
  var key = string(bufnr)
  if !has_key(buffers, key)
    buffers[key] = {text: util.BufText(bufnr), pins: [], listener: -1, timer: -1}
  endif
  EnsureLoaded(bufnr)
  listener_flush(bufnr)
  var pin = {id: next_id, bufnr: bufnr, uri: util.UriFromBuf(bufnr),
    line: position.line, character: position.character,
    lines: [], dirty: true, scope: requests.NewScope()}
  next_id += 1
  add(buffers[key].pins, pin)
  Place(pin)
  return pin
enddef

export def Suspend(pin: dict<any>)
  requests.Cancel(pin.scope)
  pin.dirty = true
enddef

export def Rename(bufnr: number)
  Track(bufnr)
  NotifyChanged(bufnr)
enddef

export def Unload(bufnr: number)
  var state = get(buffers, string(bufnr), {})
  if !empty(state)
    listener_flush(bufnr)
    listener_remove(state.listener)
    state.listener = -1
    for pin in state.pins
      Suspend(pin)
    endfor
  endif
enddef

export def Remove(pin: dict<any>)
  Suspend(pin)
  var key = string(pin.bufnr)
  if bufloaded(pin.bufnr)
    prop_remove({bufnr: pin.bufnr, type: PROPERTY, id: pin.id, both: true, all: true})
  endif
  var state = get(buffers, key, {})
  if empty(state)
    return
  endif
  filter(state.pins, (_, item) => item isnot pin)
  if empty(state.pins)
    if state.listener >= 0
      listener_remove(state.listener)
    endif
    if state.timer >= 0
      timer_stop(state.timer)
    endif
    remove(buffers, key)
  endif
enddef

def OnGoal(pin: dict<any>, Changed: func(), result: any, error: any)
  if type(error) == v:t_dict
    pin.lines = ['Pin error: ' .. get(error, 'message', string(error))]
  else
    pin.lines = renderer.GoalLines(result, config.Get().infoview.no_goals_text)
  endif
  Changed()
enddef

export def Refresh(pin: dict<any>, Changed: func())
  if !bufloaded(pin.bufnr)
    return
  endif
  EnsureLoaded(pin.bufnr)
  listener_flush(pin.bufnr)
  if pin.uri !=# util.UriFromBuf(pin.bufnr)
    pin.uri = util.UriFromBuf(pin.bufnr)
    pin.dirty = true
  endif
  if !pin.dirty || !get(lsp.Status(pin.bufnr), 'initialized', false)
    return
  endif
  pin.dirty = false
  var context = requests.Begin(pin.scope, pin.bufnr)
  requests.Send(context, '$/lean/plainGoal', {
    textDocument: {uri: pin.uri},
    position: {line: pin.line, character: pin.character + 1},
  }, (result, error) => OnGoal(pin, Changed, result, error))
enddef

export def Snapshot(pin: dict<any>): dict<any>
  var lines = !bufloaded(pin.bufnr) ? ['The pinned source buffer is no longer loaded.']
    : empty(pin.lines) ? ['Loading pin...'] : copy(pin.lines)
  return {id: pin.id, bufnr: pin.bufnr, uri: pin.uri, line: pin.line,
    character: pin.character, lines: lines}
enddef

defcompile
