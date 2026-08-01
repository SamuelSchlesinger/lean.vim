vim9script

import autoload 'lean/config.vim' as config
import autoload 'lean/util.vim' as util

# A deliberately small LSP 3.17 client for Lean.  Vim has jobs, channels,
# popups, signs, and text properties, but (unlike Neovim) no built-in LSP
# client.  Keeping this transport Lean-specific makes its behavior auditable.

var servers: dict<any> = {}
var buffer_roots: dict<string> = {}
var change_timers: dict<any> = {}
var last_change_flush_ms: dict<float> = {}
var diagnostics_by_uri: dict<any> = {}
var progress_by_uri: dict<any> = {}
var signs_initialized = false
var stderr_history: list<string> = []

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
  return 'Identifier'
enddef

def SemanticTypeName(token_type: string): string
  return 'LeanSemantic_' .. substitute(token_type, '[^A-Za-z0-9_]', '_', 'g')
enddef

def EnsureSemanticTypes(server: dict<any>)
  var provider = get(server.capabilities, 'semanticTokensProvider', {})
  var legend = type(provider) == v:t_dict ? get(provider, 'legend', {}) : {}
  server.semantic_token_types = get(legend, 'tokenTypes', [])
  for token_type in server.semantic_token_types
    var name = SemanticTypeName(token_type)
    execute $'highlight default link {name} {SemanticHighlight(token_type)}'
    if empty(prop_type_get(name))
      prop_type_add(name, {highlight: name, combine: true})
    endif
  endfor
enddef

def ClearSemanticTokens(server: dict<any>, bufnr: number)
  for token_type in get(server, 'semantic_token_types', [])
    try
      prop_remove({type: SemanticTypeName(token_type), all: true, bufnr: bufnr})
    catch
    endtry
  endfor
enddef

def AddPropertyBatches(bufnr: number, positions_by_type: dict<any>)
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

def OnSemanticTokens(root: string, bufnr: number, version: number,
    generation: number, result: any, error: any)
  if !has_key(servers, root) || !bufloaded(bufnr)
    return
  endif
  var server = servers[root]
  var buffer_key = string(bufnr)
  if get(server.semantic_generations, buffer_key, -1) != generation
    return
  endif
  if has_key(server.semantic_requests, buffer_key)
    remove(server.semantic_requests, buffer_key)
  endif
  if type(error) == v:t_dict
    return
  endif
  if getbufvar(bufnr, 'lean_lsp_version', -1) != version
    return
  endif
  ClearSemanticTokens(server, bufnr)
  if type(result) != v:t_dict
    return
  endif
  var data = get(result, 'data', [])
  if type(data) != v:t_list || len(data) < 5
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
    if type_index < 0 || type_index >= len(server.semantic_token_types)
      continue
    endif
    if line_index < 0 || line_index >= len(lines)
      continue
    endif
    var text = lines[line_index]
    var start_col = util.ByteColumn(text, utf16_column)
    var end_col = util.ByteColumn(text, utf16_column + length)
    var type_name = SemanticTypeName(server.semantic_token_types[type_index])
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
  AddPropertyBatches(bufnr, positions_by_type)
enddef

def RequestSemanticTokens(server: dict<any>, bufnr: number)
  if !config.Get().semantic_highlighting.enable || !bufloaded(bufnr)
    return
  endif
  var provider = get(server.capabilities, 'semanticTokensProvider', v:null)
  if type(provider) != v:t_dict || empty(get(server, 'semantic_token_types', []))
    return
  endif
  var key = string(bufnr)
  if has_key(server.semantic_requests, key)
    CancelRequest(server, server.semantic_requests[key])
  endif
  var generation = get(server.semantic_generations, key, 0) + 1
  server.semantic_generations[key] = generation
  var version = getbufvar(bufnr, 'lean_lsp_version', 0)
  var root = server.root
  var request_id = RequestNow(server, 'textDocument/semanticTokens/full', {
    textDocument: {uri: util.UriFromBuf(bufnr)},
  }, (result, error) => OnSemanticTokens(root, bufnr, version, generation, result, error))
  server.semantic_requests[key] = request_id
enddef

def RefreshSemanticTokens(server: dict<any>)
  for key in keys(server.buffers)
    RequestSemanticTokens(server, str2nr(key))
  endfor
enddef

def RootMarker(dir: string): bool
  for marker in config.Get().lsp.root_markers
    if filereadable(dir .. '/' .. marker) || isdirectory(dir .. '/' .. marker)
      return true
    endif
  endfor
  return false
enddef

export def ProjectRoot(path: string): string
  var absolute = fnamemodify(path, ':p')
  var packages = matchstr(absolute, '^.\{-}\ze/.lake/packages/')
  if !empty(packages)
    return packages
  endif

  var dir = fnamemodify(absolute, ':h')
  while !empty(dir)
    if RootMarker(dir)
      return dir
    endif
    var parent = fnamemodify(dir, ':h')
    if parent ==# dir
      break
    endif
    dir = parent
  endwhile
  return fnamemodify(absolute, ':h')
enddef

def ServerCommand(root: string): list<string>
  var configured = config.Get().lsp.command
  if type(configured) == v:t_func
    return call(configured, [root])
  elseif type(configured) == v:t_list && !empty(configured)
    return copy(configured)
  endif
  if filereadable(root .. '/lakefile.lean') || filereadable(root .. '/lakefile.toml')
    return ['lake', 'serve', '--', root]
  endif
  return ['lean', '--server', root]
enddef

def Send(server: dict<any>, message: dict<any>)
  if !has_key(server, 'channel') || ch_status(server.channel) ==# 'closed'
    return
  endif
  var payload = json_encode(message)
  ch_sendraw(server.channel, $"Content-Length: {strlen(payload)}\r\n\r\n{payload}")
enddef

def Respond(server: dict<any>, id: any, result: any, error: any = v:null)
  var response: dict<any> = {jsonrpc: '2.0', id: id}
  if type(error) == v:t_dict
    response.error = error
  else
    response.result = result
  endif
  Send(server, response)
enddef

def NotifyServer(server: dict<any>, method: string, params: any)
  Send(server, {jsonrpc: '2.0', method: method, params: params})
enddef

def CancelRequest(server: dict<any>, id: number)
  NotifyServer(server, '$/cancelRequest', {id: id})
  var key = string(id)
  if has_key(server.pending, key)
    remove(server.pending, key)
  endif
enddef

def RequestNow(server: dict<any>, method: string, params: any, callback: any): number
  var id = server.next_id
  server.next_id += 1
  if type(callback) == v:t_func
    server.pending[string(id)] = callback
  endif
  Send(server, {jsonrpc: '2.0', id: id, method: method, params: params})
  return id
enddef

def InitParams(root: string): dict<any>
  var root_uri = util.UriFromPath(root)
  return {
    processId: getpid(),
    clientInfo: {name: 'lean.vim', version: '0.1.0'},
    locale: 'en',
    rootPath: root,
    rootUri: root_uri,
    workspaceFolders: [{uri: root_uri, name: fnamemodify(root, ':t')}],
    capabilities: {
      workspace: {
        applyEdit: true,
        configuration: true,
        workspaceFolders: true,
        workspaceEdit: {documentChanges: true},
      },
      textDocument: {
        synchronization: {didSave: true, dynamicRegistration: false},
        hover: {contentFormat: ['markdown', 'plaintext']},
        definition: {linkSupport: true},
        declaration: {linkSupport: true},
        codeAction: {dataSupport: true},
        publishDiagnostics: {relatedInformation: true, tagSupport: {valueSet: [1, 2]}},
      },
      general: {positionEncodings: ['utf-16']},
      lean: {silentDiagnosticSupport: true, rpcWireFormat: 'v1'},
    },
    initializationOptions: {editDelay: 10, hasWidgets: false},
    trace: 'off',
  }
enddef

def IncrementalSync(server: dict<any>): bool
  var sync = get(server.capabilities, 'textDocumentSync', 0)
  if type(sync) == v:t_number
    return sync == 2
  elseif type(sync) == v:t_dict
    return get(sync, 'change', 0) == 2
  endif
  return false
enddef

def SendDidOpen(server: dict<any>, bufnr: number, dependency_mode: string = 'never')
  if !bufloaded(bufnr) || empty(bufname(bufnr))
    return
  endif
  var key = string(bufnr)
  var version = getbufvar(bufnr, 'lean_lsp_version', 0)
  var text = util.BufText(bufnr)
  setbufvar(bufnr, 'lean_lsp_version', version)
  NotifyServer(server, 'textDocument/didOpen', {
    textDocument: {
      uri: util.UriFromBuf(bufnr),
      languageId: 'lean',
      version: version,
      text: text,
    },
    dependencyBuildMode: dependency_mode,
  })
  server.opened[key] = true
  server.synced_texts[key] = text
  setbufvar(bufnr, 'lean_lsp_attached', true)
  RequestSemanticTokens(server, bufnr)
enddef

def OnInitialized(root: string, result: any, error: any)
  if !has_key(servers, root)
    return
  endif
  var server = servers[root]
  if type(error) == v:t_dict
    server.failed = true
    util.Notify($'language server initialization failed: {get(error, "message", string(error))}', 'ErrorMsg')
    return
  endif
  server.initialized = true
  server.capabilities = type(result) == v:t_dict ? get(result, 'capabilities', {}) : {}
  EnsureSemanticTypes(server)
  NotifyServer(server, 'initialized', {})
  for key in keys(server.buffers)
    SendDidOpen(server, str2nr(key))
  endfor
  var queued = server.queue
  server.queue = []
  for request in queued
    RequestNow(server, request.method, request.params, request.callback)
  endfor
enddef

def OnStderr(root: string, _channel: channel, message: string)
  if empty(message)
    return
  endif
  add(stderr_history, message)
  if len(stderr_history) > 200
    remove(stderr_history, 0)
  endif
  if config.Get().lsp.stderr && message !~# '^warning: failed to query latest release'
    echomsg $'[lean server] {message}'
  endif
enddef

def OnExit(root: string, _job: job, status: number)
  if !has_key(servers, root)
    return
  endif
  var server = servers[root]
  server.running = false
  if !server.stopping
    util.Notify($'language server exited with status {status}', status == 0 ? 'WarningMsg' : 'ErrorMsg')
  endif
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
  return get({1: 'Error', 2: 'Warning', 3: 'Information', 4: 'Hint'}, get(diag, 'severity', 1), 'Error')
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

def RenderDiagnostics(uri: string, diagnostics: list<any>)
  EnsureSigns()
  var path = util.PathFromUri(uri)
  var bufnr = bufnr(path)
  if bufnr < 0 || !bufloaded(bufnr)
    return
  endif
  sign_unplace('lean-diagnostics', {buffer: bufnr})
  ClearDiagnosticProperties(bufnr)
  if !config.Get().signs.enable
    return
  endif

  var sign_id = 1
  var signs: list<any> = []
  var positions_by_type: dict<any> = {}
  for diagnostic in diagnostics
    var tags = get(diagnostic, 'leanTags', [])
    var range = get(diagnostic, 'fullRange', get(diagnostic, 'range', {}))
    if empty(range)
      continue
    endif
    if tags ==# [1]
      add(signs, {
        id: sign_id,
        group: 'lean-diagnostics',
        name: 'LeanGoalUnsolved',
        buffer: bufnr,
        lnum: range.end.line + 1,
        priority: 11,
      })
      sign_id += 1
      continue
    elseif tags ==# [2]
      add(signs, {
        id: sign_id,
        group: 'lean-diagnostics',
        name: 'LeanGoalAccomplished',
        buffer: bufnr,
        lnum: range.start.line + 1,
        priority: 11,
      })
      sign_id += 1
      continue
    elseif get(diagnostic, 'isSilent', false)
      continue
    endif

    var severity = DiagnosticSeverity(diagnostic)
    add(signs, {
      id: sign_id,
      group: 'lean-diagnostics',
      name: 'LeanDiagnostic' .. severity,
      buffer: bufnr,
      lnum: range.start.line + 1,
      priority: 15 - get(diagnostic, 'severity', 1),
    })
    sign_id += 1

    try
      var start_line = range.start.line + 1
      var end_line = range.end.line + 1
      var start_text = getbufline(bufnr, start_line)[0]
      var end_text = getbufline(bufnr, end_line)[0]
      var start_col = util.ByteColumn(start_text, range.start.character) + 1
      var end_col = util.ByteColumn(end_text, range.end.character) + 1
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

def RenderProgress(uri: string, processing: list<any>)
  EnsureSigns()
  var bufnr = bufnr(util.PathFromUri(uri))
  if bufnr < 0 || !bufloaded(bufnr)
    return
  endif
  sign_unplace('lean-progress', {buffer: bufnr})
  if !config.Get().progress_bars.enable
    return
  endif
  var line_count = len(getbufline(bufnr, 1, '$'))
  var sign_id = 1
  var signs: list<any> = []
  for info in processing
    var range = get(info, 'range', {})
    if empty(range)
      continue
    endif
    var first = max([0, range.start.line])
    var last = min([line_count - 1, range.end.line])
    if last < first
      continue
    endif
    for line_index in range(first, last)
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
  if !empty(signs)
    sign_placelist(signs)
  endif
enddef

def HandleNotification(root: string, message: dict<any>)
  var method = message.method
  var params = get(message, 'params', {})
  if method ==# 'textDocument/publishDiagnostics'
    diagnostics_by_uri[params.uri] = get(params, 'diagnostics', [])
    RenderDiagnostics(params.uri, diagnostics_by_uri[params.uri])
    silent doautocmd <nomodeline> User LeanDiagnosticsUpdate
  elseif method ==# '$/lean/fileProgress'
    var uri = params.textDocument.uri
    progress_by_uri[uri] = get(params, 'processing', [])
    RenderProgress(uri, progress_by_uri[uri])
    silent doautocmd <nomodeline> User LeanProgressUpdate
  elseif method ==# 'window/showMessage'
    util.Notify(get(params, 'message', 'Lean server message'), get(params, 'type', 3) == 1 ? 'ErrorMsg' : 'WarningMsg')
  elseif method ==# 'window/logMessage'
    add(stderr_history, get(params, 'message', ''))
  endif
enddef

export def ApplyWorkspaceEdit(edit: dict<any>): bool
  var applied = true
  for [uri, edits] in items(get(edit, 'changes', {}))
    applied = util.ApplyTextEdits(uri, edits) && applied
  endfor
  for change in get(edit, 'documentChanges', [])
    if has_key(change, 'edits') && has_key(change, 'textDocument')
      applied = util.ApplyTextEdits(change.textDocument.uri, change.edits) && applied
    else
      applied = false
    endif
  endfor
  return applied
enddef

def HandleServerRequest(root: string, server: dict<any>, message: dict<any>)
  var method = message.method
  var params = get(message, 'params', {})
  if method ==# 'workspace/configuration'
    var result: list<any> = []
    for _ in get(params, 'items', [])
      add(result, v:null)
    endfor
    Respond(server, message.id, result)
  elseif method ==# 'workspace/workspaceFolders'
    Respond(server, message.id, [{uri: util.UriFromPath(root), name: fnamemodify(root, ':t')}])
  elseif method ==# 'workspace/applyEdit'
    Respond(server, message.id, {applied: ApplyWorkspaceEdit(get(params, 'edit', {}))})
  elseif method ==# 'workspace/semanticTokens/refresh'
    Respond(server, message.id, v:null)
    RefreshSemanticTokens(server)
  elseif index([
      'window/workDoneProgress/create',
      'client/registerCapability',
      'client/unregisterCapability',
      'workspace/inlayHint/refresh',
      'workspace/codeLens/refresh',
    ], method) >= 0
    Respond(server, message.id, v:null)
  elseif method ==# 'window/showMessageRequest'
    Respond(server, message.id, get(get(params, 'actions', []), 0, v:null))
  else
    Respond(server, message.id, v:null, {code: -32601, message: $'unsupported client request: {method}'})
  endif
enddef

def Dispatch(root: string, message: any)
  if type(message) != v:t_dict || !has_key(servers, root)
    return
  endif
  var server = servers[root]
  if has_key(message, 'method') && has_key(message, 'id')
    HandleServerRequest(root, server, message)
  elseif has_key(message, 'method')
    HandleNotification(root, message)
  elseif has_key(message, 'id')
    var key = string(message.id)
    if has_key(server.pending, key)
      var callback = remove(server.pending, key)
      call(callback, [get(message, 'result', v:null), get(message, 'error', v:null)])
    endif
  endif
enddef

def OnStdout(root: string, _channel: channel, chunk: string)
  if !has_key(servers, root)
    return
  endif
  var server = servers[root]
  server.recv ..= chunk
  while true
    var header_end = stridx(server.recv, "\r\n\r\n")
    if header_end < 0
      return
    endif
    var header = strpart(server.recv, 0, header_end)
    var length_text = matchstr(header, '\cContent-Length:\s*\zs\d\+')
    if empty(length_text)
      server.recv = strpart(server.recv, header_end + 4)
      continue
    endif
    var body_length = str2nr(length_text)
    var body_start = header_end + 4
    if strlen(server.recv) < body_start + body_length
      return
    endif
    var body = strpart(server.recv, body_start, body_length)
    server.recv = strpart(server.recv, body_start + body_length)
    var decoded: any = v:null
    try
      decoded = json_decode(body)
    catch
      util.Notify($'invalid JSON-RPC message: {v:exception}', 'ErrorMsg')
      continue
    endtry
    try
      Dispatch(root, decoded)
    catch
      util.Notify($'failed to handle JSON-RPC message: {v:exception}', 'ErrorMsg')
    endtry
  endwhile
enddef

def StartServer(root: string): dict<any>
  var command = ServerCommand(root)
  var server: dict<any> = {
    root: root,
    command: command,
    next_id: 1,
    pending: {},
    queue: [],
    recv: '',
    buffers: {},
    opened: {},
    synced_texts: {},
    semantic_requests: {},
    semantic_generations: {},
    capabilities: {},
    initialized: false,
    failed: false,
    running: true,
    stopping: false,
  }
  servers[root] = server
  try
    server.job = job_start(command, {
      cwd: root,
      in_io: 'pipe',
      out_io: 'pipe',
      err_io: 'pipe',
      in_mode: 'raw',
      out_mode: 'raw',
      err_mode: 'nl',
      out_cb: (channel, message) => OnStdout(root, channel, message),
      err_cb: (channel, message) => OnStderr(root, channel, message),
      exit_cb: (job_object, status) => OnExit(root, job_object, status),
    })
    server.channel = job_getchannel(server.job)
    if job_status(server.job) ==# 'fail'
      throw $'unable to start {join(command, " ")}'
    endif
    RequestNow(server, 'initialize', InitParams(root),
      (result, error) => OnInitialized(root, result, error))
  catch
    server.failed = true
    server.running = false
    util.Notify($'cannot start Lean language server: {v:exception}', 'ErrorMsg')
  endtry
  return server
enddef

def EnsureServer(root: string): dict<any>
  if has_key(servers, root) && servers[root].running
    return servers[root]
  endif
  return StartServer(root)
enddef

export def Attach(bufnr: number): bool
  if !config.Get().lsp.enable || empty(bufname(bufnr))
    return false
  endif
  var root = ProjectRoot(bufname(bufnr))
  var key = string(bufnr)
  buffer_roots[key] = root
  setbufvar(bufnr, 'lean_lsp_root', root)
  var server = EnsureServer(root)
  server.buffers[key] = true
  if server.initialized && !has_key(server.opened, key)
    SendDidOpen(server, bufnr)
  endif
  return !server.failed
enddef

export def Detach(bufnr: number)
  var key = string(bufnr)
  if has_key(change_timers, key)
    timer_stop(remove(change_timers, key))
  endif
  if has_key(last_change_flush_ms, key)
    remove(last_change_flush_ms, key)
  endif
  if !has_key(buffer_roots, key)
    return
  endif
  var root = remove(buffer_roots, key)
  if !has_key(servers, root)
    return
  endif
  var server = servers[root]
  if has_key(server.opened, key)
    NotifyServer(server, 'textDocument/didClose', {textDocument: {uri: util.UriFromBuf(bufnr)}})
    remove(server.opened, key)
  endif
  if has_key(server.synced_texts, key)
    remove(server.synced_texts, key)
  endif
  if has_key(server.semantic_requests, key)
    CancelRequest(server, server.semantic_requests[key])
    remove(server.semantic_requests, key)
  endif
  if has_key(server.semantic_generations, key)
    remove(server.semantic_generations, key)
  endif
  if has_key(server.buffers, key)
    remove(server.buffers, key)
  endif
  ClearSemanticTokens(server, bufnr)
  setbufvar(bufnr, 'lean_lsp_attached', false)
enddef

def FlushChange(bufnr: number)
  var key = string(bufnr)
  if has_key(change_timers, key)
    remove(change_timers, key)
  endif
  if !has_key(buffer_roots, key) || !bufloaded(bufnr)
    return
  endif
  var root = buffer_roots[key]
  if !has_key(servers, root) || !servers[root].initialized
    return
  endif
  var server = servers[root]
  var current_text = util.BufText(bufnr)
  var previous_text = get(server.synced_texts, key, v:null)
  if type(previous_text) == v:t_string && previous_text ==# current_text
    return
  endif
  var version = getbufvar(bufnr, 'lean_lsp_version', 0) + 1
  setbufvar(bufnr, 'lean_lsp_version', version)
  var content_changes = type(previous_text) == v:t_string && IncrementalSync(server)
    ? [util.IncrementalChange(previous_text, current_text)]
    : [{text: current_text}]
  NotifyServer(server, 'textDocument/didChange', {
    textDocument: {uri: util.UriFromBuf(bufnr), version: version},
    contentChanges: content_changes,
  })
  server.synced_texts[key] = current_text
  last_change_flush_ms[key] = reltimefloat(reltime()) * 1000
  RequestSemanticTokens(server, bufnr)
enddef

export def DidChange(bufnr: number)
  var key = string(bufnr)
  if !has_key(buffer_roots, key)
    return
  endif
  var delay = max([0, config.Get().lsp.change_delay])
  if !has_key(change_timers, key)
      && reltimefloat(reltime()) * 1000
        - get(last_change_flush_ms, key, -1.0) >= delay
    FlushChange(bufnr)
    return
  endif
  if has_key(change_timers, key)
    timer_stop(change_timers[key])
  endif
  change_timers[key] = timer_start(delay,
    (_) => FlushChange(bufnr))
enddef

export def DidSave(bufnr: number)
  var key = string(bufnr)
  if !has_key(buffer_roots, key)
    return
  endif
  FlushChange(bufnr)
  var server = servers[buffer_roots[key]]
  NotifyServer(server, 'textDocument/didSave', {
    textDocument: {uri: util.UriFromBuf(bufnr)},
    text: util.BufText(bufnr),
  })
enddef

export def Request(bufnr: number, method: string, params: any, callback: any): number
  var key = string(bufnr)
  if !has_key(buffer_roots, key) && !Attach(bufnr)
    if type(callback) == v:t_func
      call(callback, [v:null, {code: -32000, message: 'Lean language server is unavailable'}])
    endif
    return -1
  endif
  var server = servers[buffer_roots[key]]
  if server.failed
    if type(callback) == v:t_func
      call(callback, [v:null, {code: -32000, message: 'Lean language server failed to start'}])
    endif
    return -1
  endif
  if !server.initialized
    add(server.queue, {method: method, params: params, callback: callback})
    return 0
  endif
  return RequestNow(server, method, params, callback)
enddef

export def Notify(bufnr: number, method: string, params: any)
  var key = string(bufnr)
  if has_key(buffer_roots, key) && has_key(servers, buffer_roots[key])
    NotifyServer(servers[buffer_roots[key]], method, params)
  endif
enddef

export def RestartFile(bufnr: number)
  var key = string(bufnr)
  if !has_key(buffer_roots, key) && !Attach(bufnr)
    return
  endif
  var server = servers[buffer_roots[key]]
  NotifyServer(server, 'textDocument/didClose', {textDocument: {uri: util.UriFromBuf(bufnr)}})
  SendDidOpen(server, bufnr, 'once')
enddef

def StopServer(root: string)
  if !has_key(servers, root)
    return
  endif
  var server = servers[root]
  server.stopping = true
  if server.initialized
    RequestNow(server, 'shutdown', v:null, (_result, _error) => NotifyServer(server, 'exit', v:null))
  endif
  if has_key(server, 'job') && job_status(server.job) ==# 'run'
    job_stop(server.job)
  endif
  remove(servers, root)
enddef

export def RestartServer(bufnr: number)
  var key = string(bufnr)
  if !has_key(buffer_roots, key)
    Attach(bufnr)
    return
  endif
  var root = buffer_roots[key]
  var buffers = keys(servers[root].buffers)
  StopServer(root)
  for buffer_key in buffers
    remove(buffer_roots, buffer_key)
    Attach(str2nr(buffer_key))
  endfor
enddef

export def StopAll()
  for root in copy(keys(servers))
    StopServer(root)
  endfor
enddef

export def Diagnostics(uri: string): list<any>
  return get(diagnostics_by_uri, uri, [])
enddef

export def DiagnosticsAt(bufnr: number, line_index: number): list<any>
  var result: list<any> = []
  for diagnostic in Diagnostics(util.UriFromBuf(bufnr))
    if get(diagnostic, 'isSilent', false)
      continue
    endif
    var range = get(diagnostic, 'fullRange', get(diagnostic, 'range', {}))
    if !empty(range) && line_index >= range.start.line && line_index <= range.end.line
      add(result, diagnostic)
    endif
  endfor
  return result
enddef

export def ProgressAt(bufnr: number, line_index: number): bool
  for info in get(progress_by_uri, util.UriFromBuf(bufnr), [])
    var range = get(info, 'range', {})
    if !empty(range) && line_index >= range.start.line && line_index <= range.end.line
      return true
    endif
  endfor
  return false
enddef

export def Stderr(): list<string>
  return copy(stderr_history)
enddef

export def Status(bufnr: number): dict<any>
  var key = string(bufnr)
  if !has_key(buffer_roots, key)
    return {attached: false}
  endif
  var root = buffer_roots[key]
  var server = get(servers, root, {})
  return {
    attached: true,
    root: root,
    initialized: get(server, 'initialized', false),
    running: get(server, 'running', false),
    command: get(server, 'command', []),
  }
enddef

defcompile
