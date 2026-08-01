vim9script

# Adapted from lean.nvim's lua/lean/abbreviations.lua.
# SPDX-License-Identifier: MIT

import autoload 'lean/config.vim' as config
import autoload 'lean/util.vim' as util

var base_abbreviations: dict<string> = {}
var all_abbreviations: dict<string> = {}
var sources_by_initial: dict<list<string>> = {}

def Load(): dict<string>
  if !empty(base_abbreviations)
    return base_abbreviations
  endif
  var candidates = globpath(&runtimepath, 'data/lean/abbreviations.json', false, true)
  if empty(candidates)
    util.Notify('cannot find data/lean/abbreviations.json', 'ErrorMsg')
    return {}
  endif
  try
    base_abbreviations = json_decode(join(readfile(candidates[0]), "\n"))
  catch
    util.Notify($'cannot load Lean abbreviations: {v:exception}', 'ErrorMsg')
  endtry
  return base_abbreviations
enddef

def All(): dict<string>
  if empty(all_abbreviations)
    all_abbreviations = copy(Load())
    extend(all_abbreviations, config.Get().abbreviations.extra, 'force')
    for source in keys(all_abbreviations)
      if empty(source)
        continue
      endif
      var initial = strpart(source, 0, 1)
      if !has_key(sources_by_initial, initial)
        sources_by_initial[initial] = []
      endif
      add(sources_by_initial[initial], source)
    endfor
  endif
  return all_abbreviations
enddef

def CommonPrefixLength(left: string, right: string): number
  var maximum = min([strlen(left), strlen(right)])
  var length = 0
  while length < maximum
      && strpart(left, length, 1) ==# strpart(right, length, 1)
    length += 1
  endwhile
  # A bytewise match between different UTF-8 code points can stop inside a
  # character. Conversion consumes bytes, so return only a shared boundary.
  while length > 0
      && (byteidx(left, charidx(left, length)) != length
        || byteidx(right, charidx(right, length)) != length)
    length -= 1
  endwhile
  return length
enddef

export def ConvertText(text: string): string
  var leader = config.Get().abbreviations.leader
  if stridx(text, leader) != 0
    return text
  endif
  var rest = strpart(text, strlen(leader))
  if stridx(rest, leader) == 0
    return leader .. ConvertText(strpart(rest, strlen(leader)))
  endif

  var abbreviations = All()
  # Almost all interactive conversions are complete abbreviations. Avoid an
  # O(vocabulary-size) longest-prefix scan for that common case.
  if !empty(rest) && has_key(abbreviations, rest)
    return abbreviations[rest]
  endif

  var match_length = 0
  var source_length = 999999
  var replacement = ''
  # A candidate with a different first byte has a zero-length common prefix
  # and can never win. The index keeps the less common partial-match path
  # equivalent while avoiding a scan of the full vocabulary.
  for source in get(sources_by_initial, strpart(rest, 0, 1), [])
    var target = abbreviations[source]
    var current = CommonPrefixLength(rest, source)
    if current > match_length || (current == match_length && strlen(source) < source_length)
      match_length = current
      source_length = strlen(source)
      replacement = target
    endif
  endfor
  if match_length == 0
    return leader .. rest
  endif
  return replacement .. ConvertText(strpart(rest, match_length))
enddef

def ClearMark(bufnr: number)
  setbufvar(bufnr, 'lean_abbrev_active', false)
  setbufvar(bufnr, 'lean_abbrev_line', 0)
  setbufvar(bufnr, 'lean_abbrev_start', -1)
enddef

def RestoreMappings(bufnr: number)
  if !bufexists(bufnr)
    return
  endif
  var saved: dict<any> = getbufvar(bufnr, 'lean_abbrev_saved_maps', {})
  for key in ['tab', 'cr']
    var lhs = key ==# 'tab' ? '<Tab>' : '<CR>'
    execute $'silent! iunmap <buffer> {lhs}'
    if has_key(saved, key) && !empty(saved[key])
      mapset('i', false, saved[key])
    endif
  endfor
  setbufvar(bufnr, 'lean_abbrev_saved_maps', {})
  ClearMark(bufnr)
enddef

def InstallMappings(bufnr: number)
  var saved = {
    tab: maparg('<Tab>', 'i', false, true),
    cr: maparg('<CR>', 'i', false, true),
  }
  setbufvar(bufnr, 'lean_abbrev_saved_maps', saved)
  execute 'inoremap <silent><buffer><expr> <Tab> lean#abbreviations#Key("\<Tab>")'
  execute 'inoremap <silent><buffer><expr> <CR> lean#abbreviations#Key("\<CR>")'
enddef

def ConvertedWithCursor(typed: string): dict<any>
  var converted = ConvertText(typed)
  var marker = stridx(converted, '$CURSOR')
  if marker < 0
    return {text: converted, cursor: strlen(converted)}
  endif
  return {
    text: strpart(converted, 0, marker) .. strpart(converted, marker + strlen('$CURSOR')),
    cursor: marker,
  }
enddef

def ExpandBuffer(bufnr: number, collapse: bool = false)
  if bufnr != bufnr() || !getbufvar(bufnr, 'lean_abbrev_active', false)
    RestoreMappings(bufnr)
    return
  endif
  var row = getbufvar(bufnr, 'lean_abbrev_line', 0)
  var start = getbufvar(bufnr, 'lean_abbrev_start', -1)
  if row != line('.') || start < 0
    RestoreMappings(bufnr)
    return
  endif
  var text = getline(row)
  var cursor_byte = col('.') - 1
  var delimiter_byte = cursor_byte
  if delimiter_byte < strlen(text) && strpart(text, delimiter_byte, 1) =~# '\s'
    # Cursor is on the delimiter inserted after the abbreviation.
  elseif delimiter_byte > 0 && strpart(text, delimiter_byte - 1, 1) =~# '\s'
    delimiter_byte -= 1
  else
    delimiter_byte = min([strlen(text), col('.')])
  endif
  var typed = strpart(text, start, delimiter_byte - start)
  var conversion = collapse
    ? {text: config.Get().abbreviations.leader, cursor: strlen(config.Get().abbreviations.leader)}
    : ConvertedWithCursor(typed)
  if conversion.text !=# typed
    var updated = strpart(text, 0, start) .. conversion.text .. strpart(text, delimiter_byte)
    setline(row, updated)
    cursor(row, start + conversion.cursor + 1)
  endif
  RestoreMappings(bufnr)
enddef

def OnInsertCharPre()
  var bufnr = bufnr()
  var leader = config.Get().abbreviations.leader
  var active = getbufvar(bufnr, 'lean_abbrev_active', false)
  if !active && v:char ==# leader
    setbufvar(bufnr, 'lean_abbrev_active', true)
    setbufvar(bufnr, 'lean_abbrev_line', line('.'))
    setbufvar(bufnr, 'lean_abbrev_start', col('.') - 1)
    InstallMappings(bufnr)
    return
  endif
  if !active
    return
  endif
  if getbufvar(bufnr, 'lean_abbrev_line', 0) != line('.')
    timer_start(0, (_) => RestoreMappings(bufnr))
  elseif v:char ==# ' '
    timer_start(0, (_) => ExpandBuffer(bufnr))
  elseif v:char ==# leader
    var start = getbufvar(bufnr, 'lean_abbrev_start', -1)
    var typed = strpart(getline('.'), start, col('.') - start)
    if typed ==# leader
      timer_start(0, (_) => ExpandBuffer(bufnr, true))
    endif
  endif
enddef

def OnInsertLeave(bufnr: number)
  if getbufvar(bufnr, 'lean_abbrev_active', false)
    ExpandBuffer(bufnr)
  endif
enddef

export def Key(key: string): string
  var bufnr = bufnr()
  if !getbufvar(bufnr, 'lean_abbrev_active', false)
    return key
  endif
  var row = getbufvar(bufnr, 'lean_abbrev_line', 0)
  var start = getbufvar(bufnr, 'lean_abbrev_start', -1)
  if row != line('.') || start < 0
    timer_start(0, (_) => RestoreMappings(bufnr))
    return key
  endif
  var typed = strpart(getline('.'), start, col('.') - start)
  var conversion = ConvertedWithCursor(typed)
  timer_start(0, (_) => RestoreMappings(bufnr))
  if conversion.text ==# typed
    return key
  endif
  var move_left = strchars(conversion.text) - strchars(strpart(conversion.text, 0, conversion.cursor))
  var delimiter = key ==# "\<Tab>" ? '' : key
  return repeat("\<BS>", strchars(typed)) .. conversion.text .. delimiter .. repeat("\<Left>", move_left)
enddef

export def SetupBuffer(bufnr: number)
  if !config.Get().abbreviations.enable
    return
  endif
  Load()
  var group = $'lean_abbreviations_{bufnr}'
  execute $'augroup {group}'
  autocmd!
  execute $'autocmd InsertCharPre <buffer={bufnr}> call lean#abbreviations#InsertCharPre()'
  execute $'autocmd InsertLeave,BufLeave <buffer={bufnr}> call lean#abbreviations#InsertLeave({bufnr})'
  augroup END
enddef

# Legacy-callable exported wrappers are used by autocommands and <expr>
# mappings because those execute outside the importing Vim9 script context.
export def InsertCharPre()
  OnInsertCharPre()
enddef

export def InsertLeave(bufnr: number)
  OnInsertLeave(bufnr)
enddef

export def ReverseLookup()
  var tail = strpart(getline('.'), col('.') - 1)
  var character = strcharpart(tail, 0, 1)
  if empty(character)
    util.Popup('Lean abbreviation', ['No character under the cursor.'])
    return
  endif
  var matches: list<string> = []
  var leader = config.Get().abbreviations.leader
  for [source, target] in items(All())
    if stridx(tail, target) == 0
      add(matches, leader .. source)
    endif
  endfor
  sort(matches, (left, right) => strlen(left) == strlen(right)
    ? (left ==# right ? 0 : (left <# right ? -1 : 1))
    : strlen(left) - strlen(right))
  if empty(matches)
    util.Popup('Lean abbreviation', [$'No abbreviation found for {string(character)}.'])
  else
    var lines = [$'Type {character} with:']
    extend(lines, mapnew(matches, (_, match) => '  ' .. match))
    util.Popup('Lean abbreviation', lines)
  endif
enddef

defcompile
