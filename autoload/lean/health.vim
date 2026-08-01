vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/editor.vim' as editor
import autoload 'lean/lsp.vim' as lsp

# :LeanHealth — a scratch report of everything that usually explains a
# non-working setup: Vim builtins, toolchain executables, root detection,
# server state, and the effective configuration.

const REQUIRED_FUNCTIONS = [
  'uri_encode', 'uri_decode', 'utf16idx', 'indexof', 'prop_add_list',
]
const TOOLS = ['lean', 'lake', 'elan', 'curl']

def Mark(ok: bool): string
  return ok ? 'ok' : 'MISSING'
enddef

def ToolVersionLine(tool: string, result: dict<any>): string
  if result.status != 0 || empty(result.stdout)
    return $'  - {tool}: found, but --version failed'
  endif
  return $'  - {tool}: {trim(result.stdout[0])}'
enddef

def UpdateToolLine(bufnr: number, tool: string, result: dict<any>)
  if !bufloaded(bufnr)
    return
  endif
  var marker = $'  - {tool}: checking version...'
  var lines = getbufline(bufnr, 1, '$')
  var index = index(lines, marker)
  if index >= 0
    setbufvar(bufnr, '&modifiable', true)
    setbufline(bufnr, index + 1, ToolVersionLine(tool, result))
    setbufvar(bufnr, '&modifiable', false)
  endif
enddef

export def Report()
  var source_bufnr = bufnr()
  var source_name = bufname(source_bufnr)
  var source_is_lean = getbufvar(source_bufnr, '&filetype') ==# 'lean'
  var status = lsp.Status(source_bufnr)

  var lines: list<string> = ['lean.vim health', '']
  add(lines, $'Vim: {v:version / 100}.{v:version % 100} (patch level {v:versionlong % 10000})')
  for name in REQUIRED_FUNCTIONS
    add(lines, $'  - {name}(): {Mark(exists("*" .. name))}')
  endfor
  for feature in ['job', 'channel', 'popupwin', 'textprop', 'signs']
    add(lines, $'  - +{feature}: {Mark(has(feature))}')
  endfor

  add(lines, '')
  add(lines, 'Toolchain:')
  var pending_tools: list<string> = []
  for tool in TOOLS
    if executable(tool)
      add(lines, $'  - {tool}: checking version...')
      add(pending_tools, tool)
    else
      add(lines, $'  - {tool}: not found on PATH'
        .. (tool ==# 'curl' ? ' (only needed for :LeanLoogle)' : ''))
    endif
  endfor

  add(lines, '')
  add(lines, 'Current buffer:')
  if source_is_lean && !empty(source_name)
    add(lines, $'  - file: {source_name}')
    add(lines, $'  - project root: {lsp.ProjectRoot(source_name)}')
    add(lines, $'  - attached: {get(status, "attached", false)}')
    if get(status, 'attached', false)
      add(lines, $'  - server running: {get(status, "running", false)}')
      add(lines, $'  - server initialized: {get(status, "initialized", false)}')
      add(lines, $'  - server command: {join(get(status, "command", []), " ")}')
    endif
  else
    add(lines, '  - not a Lean buffer; open a .lean file for attach details')
  endif

  add(lines, '')
  add(lines, 'Data files:')
  var abbreviations = globpath(&runtimepath, 'data/lean/abbreviations.json', false, true)
  add(lines, $'  - abbreviations.json: {empty(abbreviations) ? "MISSING from runtimepath" : abbreviations[0]}')

  add(lines, '')
  add(lines, 'Configuration (effective):')
  for key in sort(keys(config.Get()))
    add(lines, $'  {key}: {string(config.Get()[key])}')
  endfor

  new
  setlocal buftype=nofile bufhidden=wipe noswapfile
  var report_bufnr = bufnr()
  execute 'file [Lean\ Health]'
  setline(1, lines)
  setlocal nomodifiable
  nnoremap <silent><buffer> q <Cmd>close<CR>

  for tool in pending_tools
    var captured = tool
    editor.RunCommandAsync([captured, '--version'], getcwd(),
      (result) => UpdateToolLine(report_bufnr, captured, result))
  endfor
enddef

defcompile
