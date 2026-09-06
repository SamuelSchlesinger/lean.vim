vim9script

import autoload 'lean/util.vim' as util

export def Apply(edit: any, SyncedText: func(number): any, Flush: func(number)): bool
  if type(edit) != v:t_dict
    return false
  endif
  var operations: list<any> = []
  if has_key(edit, 'documentChanges')
    if type(edit.documentChanges) != v:t_list
      return false
    endif
    for change in edit.documentChanges
      # Resource operations are deliberately unsupported. Reject them before
      # applying any preceding text-document edits.
      if type(change) != v:t_dict || !has_key(change, 'edits')
          || type(change.edits) != v:t_list
          || type(get(change, 'textDocument', v:null)) != v:t_dict
          || type(get(change.textDocument, 'uri', v:null)) != v:t_string
        return false
      endif
      var version = get(change.textDocument, 'version', v:null)
      if type(version) != v:t_number && type(version) != v:t_none
        return false
      endif
      add(operations, {
        uri: change.textDocument.uri,
        version: version,
        edits: change.edits,
      })
    endfor
  else
    var changes = get(edit, 'changes', {})
    if type(changes) != v:t_dict
      return false
    endif
    for [uri, edits] in items(changes)
      if type(edits) != v:t_list
        return false
      endif
      add(operations, {uri: uri, version: v:null, edits: edits})
    endfor
  endif

  var prepared_edits: list<any> = []
  var seen_uris: dict<bool> = {}
  for operation in operations
    if empty(operation.uri) || has_key(seen_uris, operation.uri)
      return false
    endif
    seen_uris[operation.uri] = true
    if type(operation.version) == v:t_number
      var target_bufnr = util.FindBuffer(util.PathFromUri(operation.uri))
      if target_bufnr < 0 || !bufloaded(target_bufnr)
          || getbufvar(target_bufnr, 'lean_lsp_version', -1) != operation.version
        return false
      endif
      var synced_text = SyncedText(target_bufnr)
      if type(synced_text) != v:t_string || util.BufText(target_bufnr) !=# synced_text
        return false
      endif
    endif
    var prepared = util.PrepareTextEdits(operation.uri, operation.edits)
    if !get(prepared, 'ok', false)
      return false
    endif
    add(prepared_edits, prepared)
  endfor

  # Nothing asynchronous can interleave with the commit below, but validate
  # every target once more before changing the first buffer. This prevents a
  # listener or prior preparation side effect from producing a partial edit.
  for prepared in prepared_edits
    if get(prepared, 'changed', false)
        && (!bufloaded(get(prepared, 'bufnr', -1))
          || !getbufvar(prepared.bufnr, '&modifiable')
          || util.BufText(prepared.bufnr) !=# prepared.original)
      return false
    endif
  endfor

  var applied_edits: list<any> = []
  for prepared in prepared_edits
    if get(prepared, 'changed', false)
      add(applied_edits, prepared)
    endif
    if !util.ApplyPreparedTextEdits(prepared)
      for applied in reverse(copy(applied_edits))
        util.RestorePreparedTextEdits(applied)
      endfor
      return false
    endif
  endfor
  # TextChanged may not run until control returns to Vim. Synchronize edits
  # before a following code-action command can observe stale server state.
  for prepared in applied_edits
    Flush(prepared.bufnr)
  endfor
  return true
enddef

defcompile
