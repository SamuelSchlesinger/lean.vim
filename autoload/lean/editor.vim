vim9script

import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/util.vim' as util

def ErrorMessage(error: any): string
  if type(error) != v:t_dict
    return string(error)
  endif
  var message = get(error, 'message', string(error))
  return type(message) == v:t_string ? message : string(message)
enddef

def OnHover(result: any, error: any)
  if type(error) == v:t_dict
    util.Popup('Lean hover', [ErrorMessage(error)])
    return
  endif
  if type(result) == v:t_dict
    util.Popup('Lean hover', util.MarkdownLines(get(result, 'contents', '')))
  endif
enddef

export def Hover(bufnr: number = bufnr())
  lsp.Request(bufnr, 'textDocument/hover', util.PositionParams(bufnr),
    (result, error) => OnHover(result, error))
enddef

def OnLocation(result: any, error: any)
  if type(error) == v:t_dict
    util.Notify(ErrorMessage(error), 'ErrorMsg')
    return
  endif
  var location = result
  if type(result) == v:t_list
    if empty(result)
      util.Notify('no location found')
      return
    endif
    location = result[0]
  endif
  if !util.OpenLocation(location)
    util.Notify('no location found')
  endif
enddef

export def Goto(method: string, bufnr: number = bufnr())
  lsp.Request(bufnr, method, util.PositionParams(bufnr),
    (result, error) => OnLocation(result, error))
enddef

def LocationItem(location: dict<any>): dict<any>
  var uri = get(location, 'uri', get(location, 'targetUri', ''))
  var range = get(location, 'range', get(location, 'targetSelectionRange', {}))
  if type(uri) != v:t_string || empty(uri) || type(range) != v:t_dict
      || type(get(range, 'start', v:null)) != v:t_dict
      || type(get(range.start, 'line', v:null)) != v:t_number
      || type(get(range.start, 'character', v:null)) != v:t_number
      || range.start.line < 0 || range.start.character < 0
    return {}
  endif
  var path = util.PathFromUri(uri)
  if empty(path)
    return {}
  endif
  var line_number = range.start.line + 1
  var line_text = ''
  var target_bufnr = util.FindBuffer(path)
  if target_bufnr >= 0 && bufloaded(target_bufnr)
    var lines = getbufline(target_bufnr, line_number)
    line_text = empty(lines) ? '' : lines[0]
  elseif filereadable(path)
    var lines = readfile(path, '', line_number)
    line_text = len(lines) >= line_number ? lines[line_number - 1] : ''
  endif
  return {
    filename: path,
    lnum: line_number,
    col: util.ByteColumn(line_text, range.start.character) + 1,
    text: line_text,
  }
enddef

def OnReferences(result: any, error: any)
  if type(error) == v:t_dict
    util.Notify(ErrorMessage(error), 'ErrorMsg')
    return
  endif
  var items: list<any> = []
  if type(result) == v:t_list
    for location in result
      if type(location) == v:t_dict
        var item = LocationItem(location)
        if !empty(item)
          add(items, item)
        endif
      endif
    endfor
  endif
  setqflist([], 'r', {title: 'Lean references', items: items})
  if empty(items)
    util.Notify('no references found')
  else
    copen
  endif
enddef

export def References(bufnr: number = bufnr())
  var params = util.PositionParams(bufnr)
  params.context = {includeDeclaration: true}
  lsp.Request(bufnr, 'textDocument/references', params,
    (result, error) => OnReferences(result, error))
enddef

def OnRename(result: any, error: any)
  if type(error) == v:t_dict
    util.Notify(ErrorMessage(error), 'ErrorMsg')
  elseif type(result) == v:t_dict
    if !lsp.ApplyWorkspaceEdit(result)
      util.Notify('Lean rename returned an unsupported workspace edit', 'ErrorMsg')
    endif
  endif
enddef

export def Rename(bufnr: number = bufnr())
  var old_name = expand('<cword>')
  var new_name = input('New name: ', old_name)
  if empty(new_name) || new_name ==# old_name
    return
  endif
  var params = util.PositionParams(bufnr)
  params.newName = new_name
  lsp.Request(bufnr, 'textDocument/rename', params,
    (result, error) => OnRename(result, error))
enddef

def OnExecuted(_result: any, error: any)
  if type(error) == v:t_dict
    util.Notify(ErrorMessage(error), 'ErrorMsg')
  endif
enddef

def ApplyReadyCodeAction(bufnr: number, action: dict<any>)
  if has_key(action, 'edit')
    if type(action.edit) != v:t_dict || !lsp.ApplyWorkspaceEdit(action.edit)
      util.Notify('code-action edit could not be applied; command was not executed', 'ErrorMsg')
      return
    endif
  endif
  var command = get(action, 'command', v:null)
  var command_name = ''
  var arguments: any = []
  if type(command) == v:t_string
    command_name = command
    arguments = get(action, 'arguments', [])
  elseif type(command) == v:t_dict
    command_name = get(command, 'command', '')
    arguments = get(command, 'arguments', [])
  elseif type(command) != v:t_none
    util.Notify('Lean returned an invalid code-action command', 'ErrorMsg')
    return
  endif
  if !empty(command_name)
    if type(arguments) != v:t_list
      util.Notify('Lean returned invalid code-action arguments', 'ErrorMsg')
      return
    endif
    lsp.Request(bufnr, 'workspace/executeCommand', {
      command: command_name,
      arguments: arguments,
    }, (result, error) => OnExecuted(result, error))
  elseif !has_key(action, 'edit')
    util.Notify('Lean returned a code action with no edit or command', 'ErrorMsg')
  endif
enddef

def OnResolvedCodeAction(bufnr: number, changedtick: number,
    result: any, error: any)
  if type(error) == v:t_dict
    util.Notify(ErrorMessage(error), 'ErrorMsg')
  elseif type(result) != v:t_dict
    util.Notify('Lean returned an invalid resolved code action', 'ErrorMsg')
  elseif getbufvar(bufnr, 'changedtick', -1) != changedtick
    util.Notify('buffer changed before the code action resolved; action was not applied')
  else
    ApplyReadyCodeAction(bufnr, result)
  endif
enddef

export def ApplyCodeAction(bufnr: number, action: dict<any>)
  var disabled = get(action, 'disabled', v:null)
  if type(disabled) == v:t_dict
    util.Notify(get(disabled, 'reason', 'this code action is disabled'))
    return
  endif
  if has_key(action, 'data') && !has_key(action, 'edit') && !has_key(action, 'command')
    var changedtick = getbufvar(bufnr, 'changedtick', -1)
    lsp.Request(bufnr, 'codeAction/resolve', action,
      (result, error) => OnResolvedCodeAction(bufnr, changedtick, result, error))
    return
  endif
  ApplyReadyCodeAction(bufnr, action)
enddef

def OnCodeActions(bufnr: number, changedtick: number, result: any, error: any)
  if type(error) == v:t_dict
    util.Notify(ErrorMessage(error), 'ErrorMsg')
    return
  endif
  if type(result) != v:t_list
    util.Notify('no code actions available')
    return
  endif
  if !bufloaded(bufnr) || getbufvar(bufnr, 'changedtick', -1) != changedtick
    util.Notify('buffer changed before code actions arrived; request again')
    return
  endif
  var actions = filter(copy(result), (_, action) => type(action) == v:t_dict)
  if empty(actions)
    util.Notify('no code actions available')
    return
  endif
  var choices = ['Lean code action:']
  for action in actions
    var title = get(action, 'title', '(untitled action)')
    var disabled = get(action, 'disabled', v:null)
    if type(disabled) == v:t_dict
      title ..= $' [disabled: {get(disabled, "reason", "unavailable")}]'
    endif
    add(choices, title)
  endfor
  var selection = inputlist(choices)
  if selection > 0 && selection <= len(actions)
    ApplyCodeAction(bufnr, actions[selection - 1])
  endif
enddef

export def CodeAction(bufnr: number = bufnr())
  var position = util.Position(bufnr)
  var params: dict<any> = {
    textDocument: {uri: util.UriFromBuf(bufnr)},
    range: {start: position, end: position},
    context: {diagnostics: lsp.DiagnosticsAt(bufnr, position.line)},
  }
  var changedtick = getbufvar(bufnr, 'changedtick', -1)
  lsp.Request(bufnr, 'textDocument/codeAction', params,
    (result, error) => OnCodeActions(bufnr, changedtick, result, error))
enddef

const SYMBOL_KINDS = {
  1: 'file', 2: 'module', 3: 'namespace', 4: 'package', 5: 'class',
  6: 'method', 7: 'property', 8: 'field', 9: 'constructor', 10: 'enum',
  11: 'interface', 12: 'function', 13: 'variable', 14: 'constant',
  15: 'string', 16: 'number', 17: 'boolean', 18: 'array', 19: 'object',
  # SymbolKind 24 is Event; the Lean server uses it for theorems.
  20: 'key', 21: 'null', 22: 'enum member', 23: 'struct', 24: 'theorem',
  25: 'operator', 26: 'type parameter',
}

def SymbolKindLabel(kind: any): string
  return type(kind) == v:t_number ? get(SYMBOL_KINDS, kind, '') : ''
enddef

def FlattenDocumentSymbols(bufnr: number, symbols: list<any>, depth: number,
    items: list<any>)
  for symbol in symbols
    if type(symbol) != v:t_dict
      continue
    endif
    var name = get(symbol, 'name', '')
    var range = get(symbol, 'selectionRange', get(symbol, 'range', {}))
    if type(name) != v:t_string || type(range) != v:t_dict
        || type(get(range, 'start', v:null)) != v:t_dict
        || type(get(range.start, 'line', v:null)) != v:t_number
        || range.start.line < 0
      continue
    endif
    var lnum = range.start.line + 1
    var col = 1
    var character = get(range.start, 'character', v:null)
    if type(character) == v:t_number && character >= 0
      col = util.ByteColumn(get(getbufline(bufnr, lnum), 0, ''), character) + 1
    endif
    var kind = SymbolKindLabel(get(symbol, 'kind', 0))
    add(items, {
      bufnr: bufnr,
      lnum: lnum,
      col: col,
      text: repeat('  ', depth) .. name .. (empty(kind) ? '' : $' [{kind}]'),
    })
    var children = get(symbol, 'children', [])
    if type(children) == v:t_list
      FlattenDocumentSymbols(bufnr, children, depth + 1, items)
    endif
  endfor
enddef

def OnDocumentSymbols(bufnr: number, result: any, error: any)
  if type(error) == v:t_dict
    util.Notify(ErrorMessage(error), 'ErrorMsg')
    return
  endif
  var items: list<any> = []
  if type(result) == v:t_list
    var hierarchical = indexof(result, (_, symbol) =>
      type(symbol) == v:t_dict && has_key(symbol, 'location')) < 0
    if hierarchical
      FlattenDocumentSymbols(bufnr, result, 0, items)
    else
      # SymbolInformation entries carry a full location instead of ranges.
      for symbol in result
        if type(symbol) != v:t_dict
          continue
        endif
        var item = LocationItem(get(symbol, 'location', {}))
        var name = get(symbol, 'name', '')
        if empty(item) || type(name) != v:t_string
          continue
        endif
        var kind = SymbolKindLabel(get(symbol, 'kind', 0))
        item.text = name .. (empty(kind) ? '' : $' [{kind}]')
        add(items, item)
      endfor
    endif
  endif
  setloclist(0, [], 'r', {title: 'Lean outline', items: items})
  if empty(items)
    util.Notify('no document symbols found')
  else
    lopen
  endif
enddef

export def Outline(bufnr: number = bufnr())
  lsp.Request(bufnr, 'textDocument/documentSymbol', {
    textDocument: {uri: util.UriFromBuf(bufnr)},
  }, (result, error) => OnDocumentSymbols(bufnr, result, error))
enddef

def OnWorkspaceSymbols(query: string, result: any, error: any)
  if type(error) == v:t_dict
    util.Notify(ErrorMessage(error), 'ErrorMsg')
    return
  endif
  var items: list<any> = []
  for symbol in type(result) == v:t_list ? result : []
    if type(symbol) != v:t_dict
      continue
    endif
    var name = get(symbol, 'name', '')
    var item = LocationItem(get(symbol, 'location', {}))
    if empty(item) || type(name) != v:t_string
      continue
    endif
    var kind = SymbolKindLabel(get(symbol, 'kind', 0))
    var container = get(symbol, 'containerName', '')
    var suffix = type(container) == v:t_string && !empty(container)
      ? $' ({container})'
      : ''
    item.text = name .. (empty(kind) ? '' : $' [{kind}]') .. suffix
    add(items, item)
  endfor
  setqflist([], 'r', {title: $'Lean workspace symbols: {query}', items: items})
  if empty(items)
    util.Notify($'no workspace symbols match {string(query)}')
  else
    copen
  endif
enddef

export def WorkspaceSymbols(query: string, bufnr: number = bufnr())
  lsp.Request(bufnr, 'workspace/symbol', {query: query},
    (result, error) => OnWorkspaceSymbols(query, result, error))
enddef

# All cached diagnostics for the buffer as a location list. Goal markers and
# silent diagnostics are decoration-only and are excluded.
export def DiagnosticsList(bufnr: number = bufnr())
  var severity_types = {1: 'E', 2: 'W', 3: 'I', 4: 'H'}
  var items: list<any> = []
  for diagnostic in lsp.Diagnostics(util.UriFromBuf(bufnr))
    if type(diagnostic) != v:t_dict
        || get(diagnostic, 'isSilent', false)
        || !empty(get(diagnostic, 'leanTags', []))
      continue
    endif
    var message = get(diagnostic, 'message', '')
    var range = get(diagnostic, 'range', {})
    if type(message) != v:t_string || type(range) != v:t_dict
        || type(get(range, 'start', v:null)) != v:t_dict
        || type(get(range.start, 'line', v:null)) != v:t_number
        || range.start.line < 0
      continue
    endif
    var lnum = range.start.line + 1
    var col = 1
    var line_text = get(getbufline(bufnr, lnum), 0, '')
    var character = get(range.start, 'character', v:null)
    if type(character) == v:t_number && character >= 0
      col = util.ByteColumn(line_text, character) + 1
    endif
    var severity = get(diagnostic, 'severity', 1)
    add(items, {
      bufnr: bufnr,
      lnum: lnum,
      col: col,
      text: split(message, "\n", true)[0],
      type: type(severity) == v:t_number
        ? get(severity_types, severity, 'E')
        : 'E',
    })
  endfor
  sort(items, (left, right) => left.lnum == right.lnum
    ? left.col - right.col
    : left.lnum - right.lnum)
  setloclist(0, [], 'r', {title: 'Lean diagnostics', items: items})
  if empty(items)
    util.Notify('no diagnostics in this buffer')
  else
    lopen
  endif
enddef

def LeadingIndent(text: string, tabstop: number): number
  var width = 0
  for character in split(matchstr(text, '^\s*'), '\zs')
    if character ==# "\t"
      width += tabstop - (width % tabstop)
    else
      width += strdisplaywidth(character)
    endif
  endfor
  return width
enddef

def BufferIndent(bufnr: number, line_number: number): number
  var tabstop = getbufvar(bufnr, '&tabstop')
  var current = getbufline(bufnr, line_number)
  if !empty(current)
    var current_indent = LeadingIndent(current[0], tabstop)
    if current_indent > 0
      return current_indent
    endif
  endif
  var candidate = line_number - 1
  while candidate > 0
    var lines = getbufline(bufnr, candidate)
    if !empty(lines) && !empty(trim(lines[0]))
      return LeadingIndent(lines[0], tabstop)
    endif
    candidate -= 1
  endwhile
  return 0
enddef

def OnSorryGoals(bufnr: number, line_number: number, changedtick: number,
    result: any, error: any)
  if type(error) == v:t_dict || type(result) != v:t_dict
    return
  endif
  var goals = get(result, 'goals', [])
  if type(goals) != v:t_list || empty(goals) || !bufloaded(bufnr)
    return
  endif
  if getbufvar(bufnr, 'changedtick', -1) != changedtick
    util.Notify('buffer changed before LeanSorryFill completed; no sorries inserted')
    return
  endif
  # The reply can arrive after the user switches windows. Compute indentation
  # exclusively from the target buffer rather than Vim's current buffer.
  var indentation = BufferIndent(bufnr, line_number)
  var current_lines = getbufline(bufnr, line_number)
  if !empty(current_lines) && current_lines[0] =~# '^\s*·'
    var shift = getbufvar(bufnr, '&shiftwidth')
    indentation += shift > 0 ? shift : getbufvar(bufnr, '&tabstop')
  endif
  var prefix = repeat(' ', indentation)
  var lines: list<string> = []
  if len(goals) == 1
    lines = [prefix .. 'sorry']
  else
    for _ in goals
      add(lines, prefix .. '· sorry')
    endfor
  endif
  appendbufline(bufnr, line_number, lines)
  if bufnr == bufnr()
    var focus_width = len(goals) == 1 ? 0 : strlen('· ')
    cursor(line_number + 1, indentation + focus_width + 1)
  endif
enddef

export def SorryFill(bufnr: number = bufnr())
  var line_number = line('.')
  var params = util.PositionParams(bufnr)
  var changedtick = getbufvar(bufnr, 'changedtick', -1)
  lsp.Request(bufnr, '$/lean/plainGoal', params,
    (result, error) => OnSorryGoals(bufnr, line_number, changedtick, result, error))
enddef

def DescribeImportKind(kind: dict<any>): string
  var parts: list<string> = []
  if get(kind, 'isPrivate', false)
    add(parts, 'private')
  endif
  if get(kind, 'isAll', false)
    add(parts, 'all')
  endif
  var meta = get(kind, 'metaKind', 'nonMeta')
  if meta ==# 'meta'
    add(parts, 'meta')
  elseif meta ==# 'full'
    add(parts, 'meta + non-meta')
  endif
  return empty(parts) ? '' : ' [' .. join(parts, ', ') .. ']'
enddef

def OnHierarchyResult(direction: string, result: any, request_error: any)
  if type(request_error) == v:t_dict
    util.Notify(ErrorMessage(request_error), 'ErrorMsg')
    return
  endif
  var items: list<any> = []
  for entry in type(result) == v:t_list ? result : []
    if type(entry) != v:t_dict
      continue
    endif
    var imported_module = get(entry, 'module', {})
    if type(imported_module) != v:t_dict
      continue
    endif
    var kind = get(entry, 'kind', {})
    if type(kind) != v:t_dict
      kind = {}
    endif
    var uri = get(imported_module, 'uri', '')
    var name = get(imported_module, 'name', '(unknown)')
    if type(uri) != v:t_string || empty(uri) || type(name) != v:t_string
      continue
    endif
    var path = util.PathFromUri(uri)
    if empty(path)
      continue
    endif
    add(items, {
      filename: path,
      lnum: 1,
      col: 1,
      text: name .. DescribeImportKind(kind),
    })
  endfor
  var label = direction ==# 'imports'
    ? 'Lean module imports'
    : 'Lean modules importing this file'
  setqflist([], 'r', {title: label, items: items})
  if empty(items)
    util.Notify(direction ==# 'imports'
      ? 'this module has no imports'
      : 'no modules import this file')
  else
    copen
  endif
enddef

def OnHierarchy(bufnr: number, direction: string, module: any, error: any)
  if type(error) == v:t_dict || type(module) != v:t_dict
    util.Notify(type(error) == v:t_dict ? ErrorMessage(error) : 'module hierarchy unavailable')
    return
  endif
  var method = direction ==# 'imports'
    ? '$/lean/moduleHierarchy/imports'
    : '$/lean/moduleHierarchy/importedBy'
  lsp.Request(bufnr, method, {module: module},
    (result, request_error) => OnHierarchyResult(direction, result, request_error))
enddef

export def ModuleHierarchy(direction: string, bufnr: number = bufnr())
  lsp.Request(bufnr, '$/lean/prepareModuleHierarchy', {
    textDocument: {uri: util.UriFromBuf(bufnr)},
  }, (result, error) => OnHierarchy(bufnr, direction, result, error))
enddef

def FinishCommand(state: dict<any>)
  if state.done || !state.exited || !state.closed
    return
  endif
  state.done = true
  if state.timeout_timer >= 0
    timer_stop(state.timeout_timer)
    state.timeout_timer = -1
  endif
  call(state.on_done, [{status: state.status, stdout: state.stdout, stderr: state.stderr}])
enddef

def OnCommandClosed(state: dict<any>)
  state.closed = true
  FinishCommand(state)
enddef

def OnCommandExited(state: dict<any>, status: number)
  state.exited = true
  state.status = status
  FinishCommand(state)
enddef

def KillCommand(state: dict<any>)
  state.timeout_timer = -1
  if !state.done && type(state.job) == v:t_job && job_status(state.job) ==# 'run'
    job_stop(state.job)
  endif
enddef

# Run argv in a directory and deliver {status, stdout, stderr} asynchronously.
# A cold `lake env` can take many seconds; the caller must not block redraw.
# Vim guarantees close_cb runs after the final out_cb/err_cb, so waiting for
# both close and exit means stdout is complete when on_done fires.
export def RunCommandAsync(command: list<string>, directory: string, OnDone: func(dict<any>))
  var state: dict<any> = {
    stdout: [],
    stderr: [],
    status: -1,
    exited: false,
    closed: false,
    done: false,
    timeout_timer: -1,
    job: v:null,
    on_done: OnDone,
  }
  try
    state.job = job_start(command, {
      cwd: directory,
      in_io: 'null',
      out_io: 'pipe',
      err_io: 'pipe',
      out_mode: 'nl',
      err_mode: 'nl',
      out_cb: (_channel, message) => add(state.stdout, message),
      err_cb: (_channel, message) => add(state.stderr, message),
      close_cb: (_channel) => OnCommandClosed(state),
      exit_cb: (_job, status) => OnCommandExited(state, status),
    })
  catch
    state.exited = true
    state.closed = true
    state.stderr = [v:exception]
    FinishCommand(state)
    return
  endtry
  if job_status(state.job) ==# 'fail'
    state.exited = true
    state.closed = true
    FinishCommand(state)
    return
  endif
  state.timeout_timer = timer_start(10000, (_) => KillCommand(state))
enddef

def AbsoluteSearchPath(root: string, path: string): string
  var absolute = path =~# '^/' || path =~# '^\a:[/\\]' || path =~# '^\\\\'
    ? path
    : root .. '/' .. path
  return fnamemodify(absolute, ':p')
enddef

def ParseSearchPaths(root: string, prefix: dict<any>, environment: dict<any>): list<string>
  var paths: list<string> = []
  if prefix.status == 0 && !empty(prefix.stdout)
    add(paths, fnamemodify(trim(prefix.stdout[0]) .. '/src/lean', ':p'))
  endif
  if environment.status == 0
    var source_path = ''
    for line in environment.stdout
      if line =~# '^LEAN_SRC_PATH='
        source_path = strpart(line, strlen('LEAN_SRC_PATH='))
        break
      endif
    endfor
    var separator = has('win32') ? ';' : ':'
    for path in empty(source_path) ? [] : split(source_path, separator)
      add(paths, AbsoluteSearchPath(root, path))
    endfor
  endif
  return uniq(sort(paths))
enddef

def CollectSearchResult(state: dict<any>, key: string, result: dict<any>)
  state.results[key] = result
  if type(state.results.prefix) == v:t_dict
      && type(state.results.environment) == v:t_dict
    call(state.on_done,
      [ParseSearchPaths(state.root, state.results.prefix, state.results.environment)])
  endif
enddef

export def SearchPathsAsync(OnDone: func(list<string>), bufnr: number = bufnr())
  var status = lsp.Status(bufnr)
  var root = get(status, 'root', getcwd())
  var state: dict<any> = {
    root: root,
    results: {prefix: v:null, environment: v:null},
    on_done: OnDone,
  }
  RunCommandAsync(['lean', '--print-prefix'], root,
    (result) => CollectSearchResult(state, 'prefix', result))
  RunCommandAsync(['lake', 'env'], root,
    (result) => CollectSearchResult(state, 'environment', result))
enddef

# Synchronous variant kept for scripts and tests. It waits on the async path
# (callbacks run during sleep), so it can block up to the command timeouts.
export def SearchPaths(bufnr: number = bufnr()): list<string>
  var state: dict<any> = {paths: v:null}
  SearchPathsAsync((paths: list<string>) => {
    extend(state, {paths: paths})
  }, bufnr)
  var started = reltime()
  while type(state.paths) != v:t_list && reltimefloat(reltime(started)) < 21.0
    sleep 10m
  endwhile
  return type(state.paths) == v:t_list ? state.paths : []
enddef

export def ShowSearchPaths(bufnr: number = bufnr())
  SearchPathsAsync((paths: list<string>) => {
    util.Popup('Lean search paths',
      empty(paths) ? ['No Lean search paths found.'] : paths)
  }, bufnr)
enddef

defcompile
