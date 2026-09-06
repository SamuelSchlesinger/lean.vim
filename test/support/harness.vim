vim9script

import autoload 'lean/lsp.vim' as lsp

export def WaitFor(Predicate: func(): any, timeout_ms: number = 3000): bool
  var start = reltime()
  while reltimefloat(reltime(start)) * 1000 < timeout_ms
    if Predicate()
      return true
    endif
    sleep 10m
  endwhile
  return Predicate()
enddef

export def Messages(log: string, method: string): list<any>
  var messages: list<any> = []
  for line in filereadable(log) ? readfile(log) : []
    try
      var message = json_decode(line)
      if get(message, 'method', '') ==# method
        add(messages, message)
      endif
    catch
      # A reader can observe the final line before the writer finishes it.
    endtry
  endfor
  return messages
enddef

export def Scenario(bufnr: number, method: string, scenario: string)
  var methods: dict<any> = {}
  methods[method] = {scenario: scenario}
  lsp.Notify(bufnr, 'test/configure', {methods: methods})
enddef

export def Plan(bufnr: number, method: string, responses: list<dict<any>>)
  lsp.Notify(bufnr, 'test/plan', {method: method, responses: responses})
enddef

export def Hold(bufnr: number, method: string, label: string)
  var methods: dict<any> = {}
  methods[method] = {hold: label}
  lsp.Notify(bufnr, 'test/configure', {methods: methods})
enddef

export def Barrier(bufnr: number)
  var state = {done: false}
  lsp.Request(bufnr, 'test/barrier', {}, (_result, _error) => extend(state, {done: true}))
  assert_true(WaitFor(() => state.done), 'fake server did not reach the delivery barrier')
enddef

export def Release(bufnr: number, label: string, reverse: bool = false)
  lsp.Notify(bufnr, 'test/release', {label: label, reverse: reverse})
  Barrier(bufnr)
enddef

export def Stop(log: string)
  var exits = len(Messages(log, 'exit'))
  lean#Stop()
  assert_true(WaitFor(() => len(Messages(log, 'exit')) > exits),
    'fake server did not finish the shutdown handshake')
enddef

defcompile
