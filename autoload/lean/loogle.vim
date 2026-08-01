vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/editor.vim' as editor
import autoload 'lean/util.vim' as util

# :LeanLoogle — Mathlib lemma search against loogle.lean-lang.org. Network
# access is opt-in (loogle.enable) and only ever happens on explicit command
# invocation.

# Parse a Loogle JSON response body. Exported so tests can exercise this
# without the network.
export def ParseResponse(body: string): dict<any>
  var decoded: any = v:null
  try
    decoded = json_decode(body)
  catch
    return {ok: false, error: 'Loogle returned invalid JSON', hits: []}
  endtry
  if type(decoded) != v:t_dict
    return {ok: false, error: 'Loogle returned an unexpected response', hits: []}
  endif
  var error = get(decoded, 'error', v:null)
  if type(error) == v:t_string && !empty(error)
    return {ok: false, error: split(error, "\n", true)[0], hits: []}
  endif
  var hits: list<any> = []
  for hit in type(get(decoded, 'hits', v:null)) == v:t_list ? decoded.hits : []
    if type(hit) != v:t_dict
      continue
    endif
    var name = get(hit, 'name', '')
    var hit_type = get(hit, 'type', '')
    var module = get(hit, 'module', '')
    if type(name) != v:t_string || empty(name)
      continue
    endif
    add(hits, {
      name: name,
      type: type(hit_type) == v:t_string ? hit_type : '',
      module: type(module) == v:t_string ? module : '',
    })
  endfor
  return {ok: true, error: '', hits: hits}
enddef

def RenderResults(query: string, parsed: dict<any>)
  var lines = [$'Loogle: {query}', repeat('─', 32)]
  if empty(parsed.hits)
    add(lines, 'No results.')
  endif
  for hit in parsed.hits
    add(lines, empty(hit.type) ? hit.name : $'{hit.name} : {hit.type}')
    if !empty(hit.module)
      add(lines, $'  -- {hit.module}')
    endif
  endfor
  new
  setlocal buftype=nofile bufhidden=wipe noswapfile
  setline(1, lines)
  setlocal nomodifiable
  nnoremap <silent><buffer> q <Cmd>close<CR>
enddef

def OnResponse(query: string, result: dict<any>)
  if result.status != 0
    util.Notify($'Loogle query failed (curl exit {result.status})', 'ErrorMsg')
    return
  endif
  var parsed = ParseResponse(join(result.stdout, "\n"))
  if !parsed.ok
    util.Notify(parsed.error, 'ErrorMsg')
    return
  endif
  RenderResults(query, parsed)
enddef

export def Search(query: string)
  if !config.Get().loogle.enable
    util.Notify('Loogle is disabled; enable it with g:lean_config = {"loogle": {"enable": v:true}}')
    return
  endif
  var trimmed = trim(query)
  if empty(trimmed)
    util.Notify('usage: :LeanLoogle {pattern}')
    return
  endif
  if !executable('curl')
    util.Notify('Loogle needs curl on PATH', 'ErrorMsg')
    return
  endif
  editor.RunCommandAsync([
    'curl', '-s', '--max-time', '10', '-G',
    'https://loogle.lean-lang.org/json',
    '--data-urlencode', $'q={trimmed}',
  ], getcwd(), (result) => OnResponse(trimmed, result))
enddef

defcompile
