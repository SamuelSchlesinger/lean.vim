vim9script

import autoload 'lean/documents.vim' as documents
import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/util.vim' as util

var contexts: dict<any> = {}
var next_id = 1

# A scope owns one replaceable operation, possibly containing several RPCs
# and timers. Features own scopes; this module owns their cancellation and
# document/window freshness checks. It never owns feature results or renders.
export def NewScope(): dict<any>
  return {current: {}}
enddef

export def Cancel(scope: dict<any>)
  var context = scope.current
  scope.current = {}
  if empty(context)
    return
  endif
  if has_key(contexts, string(context.id))
    remove(contexts, string(context.id))
  endif
  for timer in keys(context.timers)
    timer_stop(str2nr(timer))
  endfor
  for id in keys(context.pending)
    lsp.Cancel(context.bufnr, str2nr(id))
  endfor
  context.timers = {}
  context.pending = {}
enddef

export def CancelBuffer(bufnr: number)
  for context in values(copy(contexts))
    if context.bufnr == bufnr
      Cancel(context.scope)
    endif
  endfor
enddef

export def Begin(scope: dict<any>, bufnr: number, cursor: bool = false, check_cursor: bool = true): dict<any>
  Cancel(scope)
  lsp.Attach(bufnr)
  lsp.Flush(bufnr)
  var context = {id: next_id, scope: scope, bufnr: bufnr, document: documents.Capture(bufnr),
    cursor: cursor ? util.CursorContext() : {}, check_cursor: check_cursor, pending: {}, timers: {}}
  scope.current = context
  contexts[string(next_id)] = context
  next_id += 1
  return context
enddef

export def Active(context: dict<any>): bool
  return !empty(context) && context.scope.current is context
enddef

export def IsCurrent(context: dict<any>): bool
  return Active(context) && documents.IsCurrent(context.document)
    && (empty(context.cursor) || util.ContextIsCurrent(context.cursor, context.check_cursor))
enddef

def Reply(context: dict<any>, id: number, Callback: func(any, any),
    check_document: bool, result: any, error: any)
  if has_key(context.pending, string(id))
    remove(context.pending, string(id))
  endif
  if check_document ? IsCurrent(context) : Active(context)
    Callback(result, error)
  endif
enddef

export def Send(context: dict<any>, method: string, params: any,
    Callback: func(any, any), check_document: bool = true): number
  if !Active(context)
    return -1
  endif
  var id = -1
  id = lsp.Request(context.bufnr, method, params,
    (result, error) => Reply(context, id, Callback, check_document, result, error))
  if id > 0 && Active(context)
    context.pending[string(id)] = true
  endif
  return id
enddef

def OnTimer(context: dict<any>, Callback: func(), timer: number)
  if has_key(context.timers, string(timer))
    remove(context.timers, string(timer))
  endif
  if IsCurrent(context)
    Callback()
  endif
enddef

export def After(context: dict<any>, delay: number, Callback: func()): number
  var timer = timer_start(delay, (id) => OnTimer(context, Callback, id))
  context.timers[string(timer)] = true
  return timer
enddef

defcompile
