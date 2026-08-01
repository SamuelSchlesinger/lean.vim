vim9script

# Shared utilities for the Vim9 Lean client.

export def DeepMerge(base: dict<any>, override: dict<any>): dict<any>
  var result = deepcopy(base)
  for [key, value] in items(override)
    if has_key(result, key) && type(result[key]) == v:t_dict && type(value) == v:t_dict
      result[key] = DeepMerge(result[key], value)
    else
      result[key] = deepcopy(value)
    endif
  endfor
  return result
enddef

export def Notify(message: string, highlight: string = 'WarningMsg')
  execute $'echohl {highlight}'
  echomsg $'[lean.vim] {message}'
  echohl None
enddef

export def BufText(bufnr: number): string
  var lines = getbufline(bufnr, 1, '$')
  var text = join(lines, "\n")
  if getbufvar(bufnr, '&endofline')
    text ..= "\n"
  endif
  return text
enddef

const DIFF_CHUNK_BYTES = 4096

def IsByteBoundary(text: string, index: number): bool
  if index <= 0 || index >= strlen(text)
    return true
  endif
  return byteidx(text, charidx(text, index)) == index
enddef

def CommonPrefixBytes(old_text: string, new_text: string): number
  var maximum = min([strlen(old_text), strlen(new_text)])
  var prefix = 0
  while prefix + DIFF_CHUNK_BYTES <= maximum
      && strpart(old_text, prefix, DIFF_CHUNK_BYTES)
        ==# strpart(new_text, prefix, DIFF_CHUNK_BYTES)
    prefix += DIFF_CHUNK_BYTES
  endwhile
  # The first unequal chunk contains the boundary. Find it logarithmically;
  # thousands of one-byte strpart() calls are disproportionately expensive in
  # Vim script on large documents.
  var low = prefix
  var high = min([maximum, prefix + DIFF_CHUNK_BYTES - 1])
  while low < high
    var middle = (low + high + 1) / 2
    if strpart(old_text, prefix, middle - prefix)
        ==# strpart(new_text, prefix, middle - prefix)
      low = middle
    else
      high = middle - 1
    endif
  endwhile
  prefix = low
  # Equal UTF-8 byte prefixes can end within two different code points. LSP
  # ranges must never bisect either code point.
  while prefix > 0
      && (!IsByteBoundary(old_text, prefix) || !IsByteBoundary(new_text, prefix))
    prefix -= 1
  endwhile
  return prefix
enddef

def CommonSuffixBytes(old_text: string, new_text: string, prefix: number): number
  var old_length = strlen(old_text)
  var new_length = strlen(new_text)
  var maximum = min([old_length - prefix, new_length - prefix])
  var suffix = 0
  while suffix + DIFF_CHUNK_BYTES <= maximum
      && strpart(old_text, old_length - suffix - DIFF_CHUNK_BYTES, DIFF_CHUNK_BYTES)
        ==# strpart(new_text, new_length - suffix - DIFF_CHUNK_BYTES, DIFF_CHUNK_BYTES)
    suffix += DIFF_CHUNK_BYTES
  endwhile
  var low = suffix
  var high = min([maximum, suffix + DIFF_CHUNK_BYTES - 1])
  while low < high
    var middle = (low + high + 1) / 2
    if strpart(old_text, old_length - middle, middle - suffix)
        ==# strpart(new_text, new_length - middle, middle - suffix)
      low = middle
    else
      high = middle - 1
    endif
  endwhile
  suffix = low
  # Move a bytewise suffix forward until it begins at a UTF-8 boundary in
  # both documents.
  while suffix > 0
      && (!IsByteBoundary(old_text, old_length - suffix)
        || !IsByteBoundary(new_text, new_length - suffix))
    suffix -= 1
  endwhile
  return suffix
enddef

def PositionInText(text: string, byte_offset: number): dict<number>
  var offset = max([0, min([byte_offset, strlen(text)])])
  var before = strpart(text, 0, offset)
  var line = count(before, "\n")
  var last_newline = strridx(before, "\n")
  var line_prefix = strpart(before, last_newline + 1)
  return {
    line: line,
    character: max([0, utf16idx(line_prefix, strlen(line_prefix))]),
  }
enddef

# Return one incremental LSP content change which transforms old_text exactly
# into new_text. Coalescing to one replacement makes arbitrary edit bursts
# safe while avoiding a full-document payload.
export def IncrementalChange(old_text: string, new_text: string): dict<any>
  var prefix = CommonPrefixBytes(old_text, new_text)
  var suffix = CommonSuffixBytes(old_text, new_text, prefix)
  var old_end = strlen(old_text) - suffix
  var new_end = strlen(new_text) - suffix
  return {
    range: {
      start: PositionInText(old_text, prefix),
      end: PositionInText(old_text, old_end),
    },
    text: strpart(new_text, prefix, new_end - prefix),
  }
enddef

export def UriFromPath(path: string): string
  var absolute = fnamemodify(path, ':p')
  return 'file://' .. substitute(uri_encode(absolute), '%2F', '/', 'g')
enddef

export def UriFromBuf(bufnr: number): string
  return UriFromPath(bufname(bufnr))
enddef

export def PathFromUri(uri: string): string
  if uri !~# '^file://'
    return uri
  endif
  var path = uri_decode(substitute(uri, '^file://', '', ''))
  # file:///C:/... is the Windows spelling; strip the URI-only leading slash.
  if has('win32') && path =~# '^/[A-Za-z]:'
    path = path[1 :]
  endif
  return path
enddef

export def Position(bufnr: number, lnum: number = 0, bytecol: number = -1): dict<number>
  var line_number = lnum > 0 ? lnum : line('.')
  var column = bytecol >= 0 ? bytecol : col('.') - 1
  var text = getbufline(bufnr, line_number)[0]
  var utf16_column = utf16idx(text, min([column, strlen(text)]))
  return {line: line_number - 1, character: max([0, utf16_column])}
enddef

export def PositionParams(bufnr: number): dict<any>
  return {
    textDocument: {uri: UriFromBuf(bufnr)},
    position: Position(bufnr),
  }
enddef

export def ByteColumn(text: string, utf16_column: number): number
  var byte_column = byteidx(text, utf16_column, true)
  return byte_column < 0 ? strlen(text) : byte_column
enddef

def EditOffset(lines: list<string>, position: dict<any>): number
  if empty(lines)
    return 0
  endif
  if position.line >= len(lines)
    return strlen(join(lines, "\n"))
  endif
  var line_index = max([0, position.line])
  var offset = 0
  for index in range(line_index)
    if index == line_index
      break
    endif
    offset += strlen(lines[index]) + 1
  endfor
  return offset + ByteColumn(lines[line_index], position.character)
enddef

export def TextOffset(text: string, position: dict<any>): number
  return EditOffset(split(text, "\n", true), position)
enddef

def SetBufferText(bufnr: number, text: string)
  var lines = split(text, "\n", true)
  if !empty(lines) && lines[-1] ==# ''
    remove(lines, -1)
  endif
  if empty(lines)
    lines = ['']
  endif
  var old_count = len(getbufline(bufnr, 1, '$'))
  setbufline(bufnr, 1, lines)
  if old_count > len(lines)
    deletebufline(bufnr, len(lines) + 1, old_count)
  endif
enddef

export def ApplyTextEdits(uri: string, edits: list<any>): bool
  var path = PathFromUri(uri)
  var bufnr = bufnr(path)
  if bufnr < 0
    bufnr = bufadd(path)
  endif
  if !bufloaded(bufnr)
    bufload(bufnr)
  endif

  var lines = getbufline(bufnr, 1, '$')
  var text = join(lines, "\n")
  var with_offsets: list<any> = []
  for edit in edits
    if !has_key(edit, 'range')
      continue
    endif
    add(with_offsets, {
      start: EditOffset(lines, edit.range.start),
      finish: EditOffset(lines, edit.range.end),
      text: get(edit, 'newText', ''),
    })
  endfor
  sort(with_offsets, (left, right) => right.start - left.start)
  for edit in with_offsets
    text = strpart(text, 0, edit.start) .. edit.text .. strpart(text, edit.finish)
  endfor
  SetBufferText(bufnr, text)
  return true
enddef

export def OpenLocation(location: any): bool
  if type(location) != v:t_dict
    return false
  endif
  var uri = get(location, 'uri', get(location, 'targetUri', ''))
  var range = get(location, 'range', get(location, 'targetSelectionRange', {}))
  if empty(uri) || empty(range)
    return false
  endif
  execute 'edit ' .. fnameescape(PathFromUri(uri))
  var target_line = range.start.line + 1
  var line_text = getline(target_line)
  var target_col = ByteColumn(line_text, range.start.character) + 1
  cursor(target_line, target_col)
  normal! zv
  return true
enddef

export def MarkdownLines(contents: any): list<string>
  var lines: list<string> = []
  if type(contents) == v:t_string
    lines = split(contents, "\n", true)
  elseif type(contents) == v:t_dict
    lines = split(get(contents, 'value', ''), "\n", true)
  elseif type(contents) == v:t_list
    for item in contents
      if !empty(lines)
        add(lines, '')
      endif
      extend(lines, MarkdownLines(item))
    endfor
  endif
  # Vim popups do not render Markdown; retain code but remove fence markers.
  return filter(lines, (_, line) => line !~# '^\s*```')
enddef

export def Popup(title: string, lines: list<string>): number
  if empty(lines) || (len(lines) == 1 && empty(lines[0]))
    return 0
  endif
  var width = min([max([40, max(mapnew(lines, (_, line) => strdisplaywidth(line))) + 2]), &columns - 4])
  return popup_atcursor(lines, {
    title: $' {title} ',
    border: [],
    padding: [0, 1, 0, 1],
    minwidth: width,
    maxwidth: width,
    maxheight: max([3, &lines - 6]),
    close: 'click',
    moved: 'any',
  })
enddef

defcompile
