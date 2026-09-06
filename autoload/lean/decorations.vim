vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/util.vim' as util

# Rendering and cached diagnostics/progress. Protocol ownership and stale
# notification rejection belong to the LSP client before data arrives here.
var diagnostics_by_uri: dict<any> = {}
var progress_by_uri: dict<any> = {}
var progress_timers: dict<number> = {}
var signs_initialized = false
const PROGRESS_MARGIN_LINES = 20
const MAX_PROGRESS_SIGNS = 1000

def BufnrForUri(uri: string): number
  return util.FindBuffer(util.PathFromUri(uri))
enddef

export def Forget(uri: string)
  for cache in [diagnostics_by_uri, progress_by_uri]
    if has_key(cache, uri)
      remove(cache, uri)
    endif
  endfor
enddef

export def Clear(bufnr: number)
  var key = string(bufnr)
  if has_key(progress_timers, key)
    timer_stop(remove(progress_timers, key))
  endif
  if bufexists(bufnr)
    sign_unplace('lean-diagnostics', {buffer: bufnr})
    sign_unplace('lean-progress', {buffer: bufnr})
    ClearDiagnosticProperties(bufnr)
  endif
enddef

export def Stop()
  for timer in values(progress_timers)
    timer_stop(timer)
  endfor
  progress_timers = {}
enddef

export def AddPropertyBatches(bufnr: number, positions_by_type: dict<any>)
  for [type_name, positions] in items(positions_by_type)
    if empty(positions)
      continue
    endif
    try
      prop_add_list({type: type_name, bufnr: bufnr}, positions)
    catch
      # A single stale range must not prevent other valid positions in the
      # same batch from rendering.
      for position in positions
        try
          prop_add(position[0], position[1], {
            type: type_name,
            end_lnum: position[2],
            end_col: position[3],
            bufnr: bufnr,
          })
        catch
        endtry
      endfor
    endtry
  endfor
enddef

def EnsureSigns()
  if signs_initialized
    return
  endif
  signs_initialized = true
  highlight default link LeanDiagnosticError DiagnosticError
  highlight default link LeanDiagnosticWarning DiagnosticWarn
  highlight default link LeanDiagnosticInformation DiagnosticInfo
  highlight default link LeanDiagnosticHint DiagnosticHint
  highlight default link LeanGoalUnsolved DiagnosticInfo
  highlight default link LeanGoalAccomplished DiagnosticOk
  highlight default LeanProgress ctermfg=215 guifg=orange
  sign_define('LeanDiagnosticError', {text: 'E', texthl: 'LeanDiagnosticError'})
  sign_define('LeanDiagnosticWarning', {text: 'W', texthl: 'LeanDiagnosticWarning'})
  sign_define('LeanDiagnosticInformation', {text: 'I', texthl: 'LeanDiagnosticInformation'})
  sign_define('LeanDiagnosticHint', {text: 'H', texthl: 'LeanDiagnosticHint'})
  sign_define('LeanGoalUnsolved', {text: 'G', texthl: 'LeanGoalUnsolved'})
  sign_define('LeanGoalAccomplished', {text: '✓', texthl: 'LeanGoalAccomplished'})
  sign_define('LeanProgress', {text: config.Get().progress_bars.character, texthl: 'LeanProgress'})
  for severity in ['Error', 'Warning', 'Information', 'Hint']
    var type_name = 'LeanDiagnosticUnderline' .. severity
    if empty(prop_type_get(type_name))
      prop_type_add(type_name, {highlight: 'LeanDiagnostic' .. severity, combine: true})
    endif
  endfor
enddef

def DiagnosticSeverity(diag: dict<any>): string
  var severity = get(diag, 'severity', 1)
  return type(severity) == v:t_number
    ? get({1: 'Error', 2: 'Warning', 3: 'Information', 4: 'Hint'}, severity, 'Error')
    : 'Error'
enddef

def DiagnosticSeverityNumber(diag: dict<any>): number
  var severity = get(diag, 'severity', 1)
  return type(severity) == v:t_number && severity >= 1 && severity <= 4
    ? severity
    : 1
enddef

def ValidRange(range: any, line_count: number): bool
  if type(range) != v:t_dict
      || type(get(range, 'start', v:null)) != v:t_dict
      || type(get(range, 'end', v:null)) != v:t_dict
    return false
  endif
  var values = [
    get(range.start, 'line', v:null),
    get(range.start, 'character', v:null),
    get(range.end, 'line', v:null),
    get(range.end, 'character', v:null),
  ]
  if indexof(values, (_, value) => type(value) != v:t_number || value < 0) >= 0
    return false
  endif
  return range.start.line < line_count
    && range.end.line >= range.start.line
    && range.end.line <= line_count
    && (range.end.line < line_count || range.end.character == 0)
    && (range.end.line != range.start.line
      || range.end.character >= range.start.character)
enddef

def LastRangeLine(range: dict<any>): number
  # LSP ends are exclusive; a range ending at column zero stops on the
  # preceding line. A zero-width diagnostic still belongs to its start line.
  return range.end.character == 0 && range.end.line > range.start.line
    ? range.end.line - 1 : range.end.line
enddef

def ProcessingLineRanges(processing: list<any>, line_count: number): list<list<number>>
  var ranges: list<list<number>> = []
  for info in processing
    if type(info) == v:t_dict && ValidRange(get(info, 'range', {}), line_count)
      add(ranges, [info.range.start.line, min([line_count - 1, LastRangeLine(info.range)])])
    endif
  endfor
  sort(ranges, (left, right) => left[0] - right[0])
  var merged: list<list<number>> = []
  for span in ranges
    if !empty(merged) && span[0] <= merged[-1][1] + 1
      merged[-1][1] = max([merged[-1][1], span[1]])
    else
      add(merged, span)
    endif
  endfor
  return merged
enddef

def ClearDiagnosticProperties(bufnr: number)
  for severity in ['Error', 'Warning', 'Information', 'Hint']
    try
      prop_remove({type: 'LeanDiagnosticUnderline' .. severity, all: true, bufnr: bufnr})
    catch
      # A just-unloaded buffer can disappear while a notification is in flight.
    endtry
  endfor
enddef

export def RenderDiagnostics(uri: string, diagnostics: list<any>)
  diagnostics_by_uri[uri] = diagnostics
  EnsureSigns()
  var bufnr = BufnrForUri(uri)
  if bufnr < 0 || !bufloaded(bufnr)
    return
  endif
  sign_unplace('lean-diagnostics', {buffer: bufnr})
  ClearDiagnosticProperties(bufnr)

  var show_signs = config.Get().signs.enable
  var buffer_lines = getbufline(bufnr, 1, '$')
  var line_count = len(buffer_lines)
  var sign_id = 1
  var signs: list<any> = []
  var positions_by_type: dict<any> = {}
  for diagnostic in diagnostics
    if type(diagnostic) != v:t_dict
      continue
    endif
    var tags = get(diagnostic, 'leanTags', [])
    var range = get(diagnostic, 'fullRange', get(diagnostic, 'range', {}))
    if !ValidRange(range, line_count)
      continue
    endif
    if tags ==# [1]
      if show_signs
        add(signs, {
          id: sign_id,
          group: 'lean-diagnostics',
          name: 'LeanGoalUnsolved',
          buffer: bufnr,
          lnum: min([LastRangeLine(range), line_count - 1]) + 1,
          priority: 11,
        })
        sign_id += 1
      endif
      continue
    elseif tags ==# [2]
      if show_signs
        add(signs, {
          id: sign_id,
          group: 'lean-diagnostics',
          name: 'LeanGoalAccomplished',
          buffer: bufnr,
          lnum: range.start.line + 1,
          priority: 11,
        })
        sign_id += 1
      endif
      continue
    elseif get(diagnostic, 'isSilent', false)
      continue
    endif

    var severity = DiagnosticSeverity(diagnostic)
    var severity_number = DiagnosticSeverityNumber(diagnostic)
    if show_signs
      add(signs, {
        id: sign_id,
        group: 'lean-diagnostics',
        name: 'LeanDiagnostic' .. severity,
        buffer: bufnr,
        lnum: range.start.line + 1,
        priority: 15 - severity_number,
      })
      sign_id += 1
    endif

    try
      var start_line = range.start.line + 1
      var end_line = min([range.end.line, line_count - 1]) + 1
      var start_text = buffer_lines[start_line - 1]
      var end_text = buffer_lines[end_line - 1]
      var start_col = util.ByteColumn(start_text, range.start.character) + 1
      var end_col = range.end.line >= line_count
        ? strlen(end_text) + 1
        : util.ByteColumn(end_text, range.end.character) + 1
      if end_line == start_line && end_col <= start_col
        end_col = start_col + 1
      endif
      var type_name = 'LeanDiagnosticUnderline' .. severity
      if !has_key(positions_by_type, type_name)
        positions_by_type[type_name] = []
      endif
      add(positions_by_type[type_name], [start_line, start_col, end_line, end_col])
    catch
      # Ignore stale ranges after an edit; the server will republish them.
    endtry
  endfor
  if !empty(signs)
    sign_placelist(signs)
  endif
  AddPropertyBatches(bufnr, positions_by_type)
enddef

export def RenderProgress(uri: string, processing: list<any>)
  progress_by_uri[uri] = processing
  EnsureSigns()
  var bufnr = BufnrForUri(uri)
  if bufnr < 0 || !bufloaded(bufnr)
    return
  endif
  sign_unplace('lean-progress', {buffer: bufnr})
  if !config.Get().progress_bars.enable
    return
  endif
  var spans = util.VisibleLineRanges(bufnr, PROGRESS_MARGIN_LINES)
  if empty(spans)
    return
  endif
  var line_count = len(getbufline(bufnr, 1, '$'))
  var sign_id = 1
  var signs: list<any> = []
  var processing_ranges = ProcessingLineRanges(processing, line_count)
  for span in spans
    for processing_span in processing_ranges
      var first = max([span[0] - 1, processing_span[0]])
      var last = min([span[1] - 1, processing_span[1]])
      if last < first
        continue
      endif
      for line_index in range(first, last)
        if len(signs) >= MAX_PROGRESS_SIGNS
          break
        endif
        add(signs, {
          id: sign_id,
          group: 'lean-progress',
          name: 'LeanProgress',
          buffer: bufnr,
          lnum: line_index + 1,
          priority: 5,
        })
        sign_id += 1
      endfor
    endfor
  endfor
  if !empty(signs)
    sign_placelist(signs)
  endif
enddef

export def RefreshProgress(bufnr: number)
  if !bufloaded(bufnr) || empty(bufname(bufnr))
    return
  endif
  var uri = getbufvar(bufnr, 'lean_lsp_uri', '')
  if empty(uri)
    uri = util.UriFromBuf(bufnr)
  endif
  if has_key(progress_by_uri, uri)
    RenderProgress(uri, progress_by_uri[uri])
  endif
enddef

def DebouncedProgressRender(bufnr: number)
  var key = string(bufnr)
  if has_key(progress_timers, key)
    remove(progress_timers, key)
  endif
  RefreshProgress(bufnr)
enddef

def ScheduleProgressRender(bufnr: number)
  var key = string(bufnr)
  if has_key(progress_timers, key)
    timer_stop(progress_timers[key])
  endif
  progress_timers[key] = timer_start(100, (_) => DebouncedProgressRender(bufnr))
enddef

export def OnWinScrolled()
  var scrolled = filter(keys(v:event), (_, key) => key !=# 'all')
  if empty(scrolled)
    # Called outside a WinScrolled autocmd: refresh every attached buffer.
    for uri in keys(progress_by_uri)
      ScheduleProgressRender(BufnrForUri(uri))
    endfor
    return
  endif
  for window_key in scrolled
    var bufnr = winbufnr(str2nr(window_key))
    if bufnr > 0 && getbufvar(bufnr, 'lean_lsp_attached', false)
      ScheduleProgressRender(bufnr)
    endif
  endfor
enddef

export def Diagnostics(uri: string): list<any>
  return get(diagnostics_by_uri, uri, [])
enddef

export def DiagnosticsAt(bufnr: number, line_index: number): list<any>
  var result: list<any> = []
  var line_count = len(getbufline(bufnr, 1, '$'))
  for diagnostic in Diagnostics(util.UriFromBuf(bufnr))
    if type(diagnostic) != v:t_dict || get(diagnostic, 'isSilent', false)
      continue
    endif
    var range = get(diagnostic, 'fullRange', get(diagnostic, 'range', {}))
    if ValidRange(range, line_count)
        && line_index >= range.start.line && line_index <= LastRangeLine(range)
      add(result, diagnostic)
    endif
  endfor
  return result
enddef

export def ProgressAt(bufnr: number, line_index: number): bool
  var line_count = len(getbufline(bufnr, 1, '$'))
  for info in get(progress_by_uri, util.UriFromBuf(bufnr), [])
    if type(info) != v:t_dict
      continue
    endif
    var range = get(info, 'range', {})
    if ValidRange(range, line_count)
        && line_index >= range.start.line && line_index <= LastRangeLine(range)
      return true
    endif
  endfor
  return false
enddef

export def ProgressSummary(bufnr: number): dict<any>
  var line_count = max([1, len(getbufline(bufnr, 1, '$'))])
  var covered = 0
  for span in ProcessingLineRanges(get(progress_by_uri, util.UriFromBuf(bufnr), []), line_count)
    covered += span[1] - span[0] + 1
  endfor
  return {
    processing: covered > 0,
    percent: min([100, covered * 100 / line_count]),
  }
enddef

export def DiagnosticCounts(bufnr: number): dict<number>
  var counts = {error: 0, warning: 0}
  for diagnostic in Diagnostics(util.UriFromBuf(bufnr))
    if type(diagnostic) != v:t_dict
        || get(diagnostic, 'isSilent', false)
        || !empty(get(diagnostic, 'leanTags', []))
      continue
    endif
    var severity = get(diagnostic, 'severity', 1)
    if severity == 1
      counts.error += 1
    elseif severity == 2
      counts.warning += 1
    endif
  endfor
  return counts
enddef

defcompile
