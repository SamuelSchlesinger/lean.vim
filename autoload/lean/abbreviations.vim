vim9script

# Adapted from lean.nvim's lua/lean/abbreviations.lua.
# SPDX-License-Identifier: MIT

import autoload 'lean/config.vim' as config
import autoload 'lean/util.vim' as util

var base_abbreviations: dict<string> = {}
var all_abbreviations: dict<string> = {}
var sources_by_initial: dict<list<string>> = {}
const property_type = 'LeanAbbreviationMark'
const property_id = 1
const trigger_mappings = {
  space: '<Space>',
  tab: '<Tab>',
  cr: '<CR>',
}

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
  if empty(leader) || strchars(leader) != 1
    return text
  endif
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

def EnsurePropertyType(bufnr: number)
  highlight default link LeanAbbreviationMark Underlined
  if empty(prop_type_get(property_type, {bufnr: bufnr}))
    prop_type_add(property_type, {
      bufnr: bufnr,
      highlight: 'LeanAbbreviationMark',
      start_incl: true,
      end_incl: true,
    })
  endif
enddef

def RestoreMappings(bufnr: number)
  if !bufexists(bufnr)
    return
  endif
  if !getbufvar(bufnr, 'lean_abbrev_maps_installed', false)
    return
  endif
  # :iunmap <buffer> and mapset() operate on the current buffer. BufLeave
  # normally invokes us while that buffer is still current; the BufEnter
  # autocmd retries restoration if another caller reaches us later.
  if bufnr != bufnr()
    return
  endif

  var saved: dict<any> = getbufvar(bufnr, 'lean_abbrev_saved_maps', {})
  # Flip the guard first so nested cleanup is harmless.
  setbufvar(bufnr, 'lean_abbrev_maps_installed', false)
  for [key, lhs] in items(trigger_mappings)
    execute $'silent! iunmap <buffer> {lhs}'
    if has_key(saved, key) && !empty(saved[key])
      mapset('i', false, saved[key])
    endif
  endfor
  setbufvar(bufnr, 'lean_abbrev_saved_maps', {})
enddef

def InstallMappings(bufnr: number)
  if getbufvar(bufnr, 'lean_abbrev_maps_installed', false)
    return
  endif
  var saved: dict<any> = {}
  for [key, lhs] in items(trigger_mappings)
    var mapping = maparg(lhs, 'i', false, true)
    # A buffer-local overlay does not disturb a global mapping, so only a
    # buffer-local mapping needs to be recreated during cleanup.
    saved[key] = !empty(mapping) && get(mapping, 'buffer', 0) ? mapping : {}
  endfor
  setbufvar(bufnr, 'lean_abbrev_saved_maps', saved)
  setbufvar(bufnr, 'lean_abbrev_maps_installed', true)
  inoremap <silent><buffer> <Space> <Cmd>call lean#abbreviations#Trigger('space')<CR>
  inoremap <silent><buffer> <Tab> <Cmd>call lean#abbreviations#Trigger('tab')<CR>
  inoremap <silent><buffer> <CR> <Cmd>call lean#abbreviations#Trigger('cr')<CR><CR>
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

def ActiveProperty(bufnr: number): dict<any>
  if !bufexists(bufnr)
    return {}
  endif
  if bufnr == bufnr()
    # The active abbreviation must end at the insert cursor. Looking only at
    # that line keeps per-keystroke validation independent of buffer size.
    for property in prop_list(line('.'), {
      bufnr: bufnr,
      ids: [property_id],
      types: [property_type],
    })
      if property.id == property_id && property.type ==# property_type
        property.lnum = line('.')
        return property
      endif
    endfor
    return {}
  endif
  # This path is only a lifecycle fallback for a buffer which ceased to be
  # current before its BufLeave cleanup could run.
  return prop_find({
    bufnr: bufnr,
    lnum: 1,
    col: 1,
    id: property_id,
    type: property_type,
    both: true,
  }, 'f')
enddef

def PropertyText(bufnr: number, property: dict<any>): string
  if empty(property) || !get(property, 'start', false) || !get(property, 'end', false)
    return ''
  endif
  var lines = getbufline(bufnr, property.lnum)
  if empty(lines)
    return ''
  endif
  return strpart(lines[0], property.col - 1, property.length)
enddef

def CursorAtPropertyEnd(bufnr: number, property: dict<any>): bool
  return bufnr == bufnr()
    && !empty(property)
    && get(property, 'start', false)
    && get(property, 'end', false)
    && property.lnum == line('.')
    && col('.') - 1 == property.col - 1 + property.length
enddef

def RemoveProperty(bufnr: number)
  if bufexists(bufnr) && !empty(prop_type_get(property_type, {bufnr: bufnr}))
    prop_remove({
      bufnr: bufnr,
      id: property_id,
      type: property_type,
      both: true,
      all: true,
    })
  endif
enddef

def ClearState(bufnr: number)
  if !bufexists(bufnr)
    return
  endif
  setbufvar(bufnr, 'lean_abbrev_active', false)
  RemoveProperty(bufnr)
  RestoreMappings(bufnr)
enddef

def Begin(bufnr: number)
  EnsurePropertyType(bufnr)
  RemoveProperty(bufnr)
  prop_add(line('.'), col('.'), {
    bufnr: bufnr,
    id: property_id,
    type: property_type,
    length: 0,
  })
  setbufvar(bufnr, 'lean_abbrev_active', true)
  InstallMappings(bufnr)
enddef

def ReplaceActive(bufnr: number, suffix: string = ''): bool
  var property = ActiveProperty(bufnr)
  var typed = PropertyText(bufnr, property)
  var leader = config.Get().abbreviations.leader
  if empty(property) || stridx(typed, leader) != 0
    ClearState(bufnr)
    return false
  endif

  var lines = getbufline(bufnr, property.lnum)
  if empty(lines)
    ClearState(bufnr)
    return false
  endif
  var original = lines[0]
  var start = property.col - 1
  var finish = start + property.length
  var conversion = ConvertedWithCursor(typed .. suffix)
  var updated = strpart(original, 0, start)
    .. conversion.text .. strpart(original, finish)

  ClearState(bufnr)
  if updated !=# original
    try
      undojoin
    catch /E790:/
    endtry
    setbufline(bufnr, property.lnum, updated)
  endif
  if bufnr == bufnr()
    cursor(property.lnum, start + conversion.cursor + 1)
  endif
  return true
enddef

def ReplayTrigger(kind: string)
  if kind ==# 'space'
    feedkeys(' ', 'im')
  elseif kind ==# 'tab'
    feedkeys("\<Tab>", 'im')
  endif
enddef

def OnInsertCharPre()
  var bufnr = bufnr()
  var leader = config.Get().abbreviations.leader
  var active = getbufvar(bufnr, 'lean_abbrev_active', false)
  if active
    var property = ActiveProperty(bufnr)
    var typed = PropertyText(bufnr, property)
    if stridx(typed, leader) != 0 || !CursorAtPropertyEnd(bufnr, property)
      ClearState(bufnr)
      active = false
    elseif v:char ==# leader && typed ==# leader
      # Suppress the second leader instead of inserting it and deleting the
      # first one on a timer. This makes escaping synchronous.
      v:char = ''
      ClearState(bufnr)
      return
    endif
  endif
  if !active && v:char ==# leader
    Begin(bufnr)
  endif
enddef

def OnInsertLeave(bufnr: number)
  if getbufvar(bufnr, 'lean_abbrev_active', false)
    ReplaceActive(bufnr)
  else
    RestoreMappings(bufnr)
  endif
enddef

export def Trigger(kind: string)
  var bufnr = bufnr()
  var property = ActiveProperty(bufnr)
  if !getbufvar(bufnr, 'lean_abbrev_active', false)
      || !CursorAtPropertyEnd(bufnr, property)
    ClearState(bufnr)
    ReplayTrigger(kind)
    return
  endif
  var suffix = kind ==# 'space' ? ' ' : ''
  if !ReplaceActive(bufnr, suffix)
    ReplayTrigger(kind)
  endif
enddef

export def SetupBuffer(bufnr: number)
  if !config.Get().abbreviations.enable
    return
  endif
  var leader = config.Get().abbreviations.leader
  if empty(leader) || strchars(leader) != 1
    util.Notify('abbreviations.leader must be exactly one character', 'ErrorMsg')
    return
  endif
  Load()
  var group = $'lean_abbreviations_{bufnr}'
  execute $'augroup {group}'
  autocmd!
  execute $'autocmd InsertCharPre <buffer={bufnr}> call lean#abbreviations#InsertCharPre()'
  execute $'autocmd InsertLeave,BufLeave <buffer={bufnr}> call lean#abbreviations#InsertLeave({bufnr})'
  execute $'autocmd BufEnter <buffer={bufnr}> call lean#abbreviations#InsertLeave({bufnr})'
  augroup END
enddef

export def TeardownBuffer(bufnr: number)
  ClearState(bufnr)
  var group = $'lean_abbreviations_{bufnr}'
  execute $'augroup {group}'
  autocmd!
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
