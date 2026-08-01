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
  var target_bufnr = bufnr(path)
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
  setqflist([], 'r', {title: $'Lean module {direction}', items: items})
  if empty(items)
    util.Notify($'no module {direction} found')
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

def RunInDirectory(command: list<string>, directory: string): dict<any>
  var stdout: list<string> = []
  var stderr: list<string> = []
  var process: job
  try
    process = job_start(command, {
      cwd: directory,
      in_io: 'null',
      out_io: 'pipe',
      err_io: 'pipe',
      out_mode: 'nl',
      err_mode: 'nl',
      out_cb: (_channel, message) => add(stdout, message),
      err_cb: (_channel, message) => add(stderr, message),
    })
  catch
    return {status: -1, stdout: [], stderr: [v:exception]}
  endtry
  if job_status(process) ==# 'fail'
    return {status: -1, stdout: [], stderr: []}
  endif
  var started = reltime()
  while job_status(process) ==# 'run' && reltimefloat(reltime(started)) < 10.0
    sleep 5m
  endwhile
  if job_status(process) ==# 'run'
    job_stop(process)
    return {status: -1, stdout: stdout, stderr: stderr}
  endif
  # Allow final channel callbacks to drain after the exit callback marks the
  # job dead.
  sleep 1m
  return {
    status: get(job_info(process), 'exitval', -1),
    stdout: stdout,
    stderr: stderr,
  }
enddef

def AbsoluteSearchPath(root: string, path: string): string
  var absolute = path =~# '^/' || path =~# '^\a:[/\\]' || path =~# '^\\\\'
    ? path
    : root .. '/' .. path
  return fnamemodify(absolute, ':p')
enddef

export def SearchPaths(bufnr: number = bufnr()): list<string>
  var status = lsp.Status(bufnr)
  var root = get(status, 'root', getcwd())
  var paths: list<string> = []
  var prefix = RunInDirectory(['lean', '--print-prefix'], root)
  if prefix.status == 0 && !empty(prefix.stdout)
    add(paths, fnamemodify(trim(prefix.stdout[0]) .. '/src/lean', ':p'))
  endif
  var environment = RunInDirectory(['lake', 'env'], root)
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

export def ShowSearchPaths(bufnr: number = bufnr())
  util.Popup('Lean search paths', SearchPaths(bufnr))
enddef

defcompile
