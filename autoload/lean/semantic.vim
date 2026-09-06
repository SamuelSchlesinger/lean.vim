vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/util.vim' as util
import autoload 'lean/lsp.vim' as lsp
import autoload 'lean/requests.vim' as requests
import autoload 'lean/decorations.vim' as decorations

var states: dict<any> = {}

export def Clear(bufnr: number)
  var key = string(bufnr)
  if has_key(states, key)
    var state = remove(states, key)
    requests.Cancel(state.scope)
    ClearSemanticTokens(state, bufnr)
  endif
enddef

def Refresh(bufnr: number, state: dict<any>, context: dict<any>)
  requests.Send(context, 'textDocument/semanticTokens/full', {
    textDocument: {uri: util.UriFromBuf(bufnr)},
  }, (result, error) => OnSemanticTokens(state, bufnr, result, error))
enddef

export def OnBufferSynced(bufnr: number)
  if !config.Get().semantic_highlighting.enable || !bufloaded(bufnr)
    return
  endif
  var capabilities = lsp.Capabilities(bufnr)
  var provider = get(capabilities, 'semanticTokensProvider', {})
  var full = type(provider) == v:t_dict ? get(provider, 'full', false) : false
  if !(type(full) == v:t_bool && full) && type(full) != v:t_dict
    return
  endif
  var key = string(bufnr)
  if !has_key(states, key)
    states[key] = {scope: requests.NewScope(), capabilities: capabilities}
  endif
  var state = states[key]
  state.capabilities = capabilities
  EnsureSemanticTypes(state)
  if empty(state.semantic_groups)
    Clear(bufnr)
    return
  endif
  var context = requests.Begin(state.scope, bufnr)
  requests.After(context, 200, () => Refresh(bufnr, state, context))
enddef

# Default highlight group for a semantic token type; '' means the type is
# not rendered. Lean emits keyword/function/variable/property, and variables
# plus property projections cover most identifiers in a file — coloring them
# buries the informative tokens, so they default to unstyled. Users opt back
# in per type with g:lean_config.semantic_highlighting.links.
def SemanticHighlight(token_type: string): string
  if index(['namespace', 'type', 'class', 'enum', 'interface', 'struct', 'typeParameter'], token_type) >= 0
    return 'Type'
  elseif index(['function', 'method'], token_type) >= 0
    return 'Function'
  elseif token_type ==# 'enumMember'
    return 'Constant'
  elseif token_type ==# 'macro'
    return 'Macro'
  elseif token_type ==# 'keyword'
    return 'Keyword'
  elseif token_type ==# 'modifier'
    return 'StorageClass'
  elseif token_type ==# 'comment'
    return 'Comment'
  elseif index(['string', 'regexp'], token_type) >= 0
    return 'String'
  elseif token_type ==# 'number'
    return 'Number'
  elseif token_type ==# 'operator'
    return 'Operator'
  elseif token_type ==# 'decorator'
    return 'PreProc'
  endif
  return ''
enddef

def SemanticGroupFor(token_type: string): string
  var links = get(config.Get().semantic_highlighting, 'links', {})
  if type(links) == v:t_dict && has_key(links, token_type)
    var target = links[token_type]
    return type(target) == v:t_string ? target : ''
  endif
  return SemanticHighlight(token_type)
enddef

def SemanticTypeName(token_type: string): string
  return 'LeanSemantic_' .. substitute(token_type, '[^A-Za-z0-9_]', '_', 'g')
enddef

def EnsureSemanticTypes(state: dict<any>)
  var provider = get(state.capabilities, 'semanticTokensProvider', {})
  var legend = type(provider) == v:t_dict ? get(provider, 'legend', {}) : {}
  var token_types = type(legend) == v:t_dict ? get(legend, 'tokenTypes', []) : []
  state.semantic_token_types = type(token_types) == v:t_list
    ? filter(copy(token_types), (_, token_type) => type(token_type) == v:t_string)
    : []
  # Only rendered token types get a group and a text-property type; the
  # rest are skipped entirely when replies are decoded.
  state.semantic_groups = {}
  for token_type in state.semantic_token_types
    var target = SemanticGroupFor(token_type)
    if empty(target)
      continue
    endif
    state.semantic_groups[token_type] = target
    var name = SemanticTypeName(token_type)
    execute $'highlight default link {name} {target}'
    if empty(prop_type_get(name))
      prop_type_add(name, {highlight: name, combine: true})
    endif
  endfor
enddef

def ClearSemanticTokens(state: dict<any>, bufnr: number)
  for token_type in keys(get(state, 'semantic_groups', {}))
    try
      prop_remove({type: SemanticTypeName(token_type), all: true, bufnr: bufnr})
    catch
    endtry
  endfor
enddef

def OnSemanticTokens(state: dict<any>, bufnr: number, result: any, error: any)
  if type(error) == v:t_dict
    return
  endif
  if type(result) != v:t_dict
    ClearSemanticTokens(state, bufnr)
    return
  endif
  var data = get(result, 'data', [])
  if type(data) != v:t_list || len(data) % 5 != 0
    ClearSemanticTokens(state, bufnr)
    return
  endif
  for value in data
    if type(value) != v:t_number || value < 0
      ClearSemanticTokens(state, bufnr)
      return
    endif
  endfor
  ClearSemanticTokens(state, bufnr)
  if empty(data)
    return
  endif
  var line_index = 0
  var utf16_column = 0
  var lines = getbufline(bufnr, 1, '$')
  var positions_by_type: dict<any> = {}
  for index in range(0, len(data) - 5, 5)
    var delta_line = data[index]
    if delta_line > 0
      line_index += delta_line
      utf16_column = data[index + 1]
    else
      utf16_column += data[index + 1]
    endif
    var length = data[index + 2]
    var type_index = data[index + 3]
    if type_index < 0 || type_index >= len(state.semantic_token_types)
      continue
    endif
    var token_type = state.semantic_token_types[type_index]
    if !has_key(get(state, 'semantic_groups', {}), token_type)
      continue
    endif
    if line_index < 0 || line_index >= len(lines)
      continue
    endif
    var text = lines[line_index]
    var start_col = util.ByteColumn(text, utf16_column)
    var end_col = util.ByteColumn(text, utf16_column + length)
    if length == 0
        || utf16idx(text, start_col) != utf16_column
        || utf16idx(text, end_col) != utf16_column + length
      continue
    endif
    var type_name = SemanticTypeName(token_type)
    if !has_key(positions_by_type, type_name)
      positions_by_type[type_name] = []
    endif
    add(positions_by_type[type_name], [
      line_index + 1,
      start_col + 1,
      line_index + 1,
      start_col + 1 + max([1, end_col - start_col]),
    ])
  endfor
  decorations.AddPropertyBatches(bufnr, positions_by_type)
enddef

defcompile
