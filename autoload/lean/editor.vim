vim9script

import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/util.vim' as util

def ErrorMessage(error: any): string
  return type(error) == v:t_dict ? get(error, 'message', string(error)) : string(error)
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
  return {
    filename: util.PathFromUri(uri),
    lnum: range.start.line + 1,
    col: range.start.character + 1,
    text: '',
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
        add(items, LocationItem(location))
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
    lsp.ApplyWorkspaceEdit(result)
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

export def ApplyCodeAction(bufnr: number, action: dict<any>)
  if has_key(action, 'edit')
    lsp.ApplyWorkspaceEdit(action.edit)
  endif
  var command = get(action, 'command', v:null)
  if type(command) == v:t_string
    lsp.Request(bufnr, 'workspace/executeCommand', {
      command: command,
      arguments: get(action, 'arguments', []),
    }, (result, error) => OnExecuted(result, error))
  elseif type(command) == v:t_dict
    lsp.Request(bufnr, 'workspace/executeCommand', {
      command: command.command,
      arguments: get(command, 'arguments', []),
    }, (result, error) => OnExecuted(result, error))
  endif
enddef

def OnCodeActions(bufnr: number, result: any, error: any)
  if type(error) == v:t_dict
    util.Notify(ErrorMessage(error), 'ErrorMsg')
    return
  endif
  if type(result) != v:t_list || empty(result)
    util.Notify('no code actions available')
    return
  endif
  var choices = ['Lean code action:']
  for action in result
    add(choices, get(action, 'title', '(untitled action)'))
  endfor
  var selection = inputlist(choices)
  if selection > 0 && selection <= len(result)
    ApplyCodeAction(bufnr, result[selection - 1])
  endif
enddef

export def CodeAction(bufnr: number = bufnr())
  var position = util.Position(bufnr)
  var params: dict<any> = {
    textDocument: {uri: util.UriFromBuf(bufnr)},
    range: {start: position, end: position},
    context: {diagnostics: lsp.DiagnosticsAt(bufnr, position.line)},
  }
  lsp.Request(bufnr, 'textDocument/codeAction', params,
    (result, error) => OnCodeActions(bufnr, result, error))
enddef

def OnSorryGoals(bufnr: number, line_number: number, result: any, error: any)
  if type(error) == v:t_dict || type(result) != v:t_dict
    return
  endif
  var goals = get(result, 'goals', [])
  if type(goals) != v:t_list || empty(goals) || !bufloaded(bufnr)
    return
  endif
  var indentation = indent(line_number)
  if indentation == 0
    indentation = indent(prevnonblank(line_number))
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
enddef

export def SorryFill(bufnr: number = bufnr())
  var line_number = line('.')
  var params = util.PositionParams(bufnr)
  params.position.character += 1
  lsp.Request(bufnr, '$/lean/plainGoal', params,
    (result, error) => OnSorryGoals(bufnr, line_number, result, error))
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
    var imported_module = get(entry, 'module', {})
    add(items, {
      filename: util.PathFromUri(get(imported_module, 'uri', '')),
      lnum: 1,
      col: 1,
      text: get(imported_module, 'name', '(unknown)') .. DescribeImportKind(get(entry, 'kind', {})),
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

export def SearchPaths(bufnr: number = bufnr()): list<string>
  var status = lsp.Status(bufnr)
  var root = get(status, 'root', getcwd())
  var paths: list<string> = []
  var previous = getcwd()
  try
    chdir(root)
    var prefix = systemlist('lean --print-prefix')
    if v:shell_error == 0 && !empty(prefix)
      add(paths, fnamemodify(prefix[0] .. '/src/lean', ':p'))
    endif
    var environment = systemlist('lake env printenv LEAN_SRC_PATH')
    if v:shell_error == 0 && !empty(environment)
      for path in split(environment[0], ':')
        add(paths, fnamemodify(path[0] ==# '/' ? path : root .. '/' .. path, ':p'))
      endfor
    endif
  finally
    chdir(previous)
  endtry
  return uniq(sort(paths))
enddef

export def ShowSearchPaths(bufnr: number = bufnr())
  util.Popup('Lean search paths', SearchPaths(bufnr))
enddef

defcompile
