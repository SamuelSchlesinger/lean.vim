vim9script

import autoload 'lean/util.vim' as util

# The LSP client alone registers document lifetimes. A new server, reopened
# file, or renamed buffer gets a new identity, even when its text is unchanged.
var documents: dict<any> = {}

export def Attach(bufnr: number, uri: string, owner: dict<any>)
  var key = string(bufnr)
  var previous = get(documents, key, {})
  if empty(previous) || previous.uri !=# uri || previous.owner isnot owner
    documents[key] = {bufnr: bufnr, uri: uri, owner: owner}
  endif
enddef

export def Detach(bufnr: number)
  var key = string(bufnr)
  if has_key(documents, key)
    remove(documents, key)
  endif
enddef

export def Capture(bufnr: number): dict<any>
  return {bufnr: bufnr, document: get(documents, string(bufnr), {}),
    uri: util.UriFromBuf(bufnr), tick: getbufvar(bufnr, 'changedtick', -1)}
enddef

export def IsCurrent(snapshot: dict<any>): bool
  return !empty(snapshot.document) && bufloaded(snapshot.bufnr)
    && get(documents, string(snapshot.bufnr), {}) is snapshot.document
    && util.UriFromBuf(snapshot.bufnr) ==# snapshot.uri
    && getbufvar(snapshot.bufnr, 'changedtick', -2) == snapshot.tick
enddef

export def CaptureProject(owner: dict<any>): list<dict<any>>
  var snapshots: list<dict<any>> = []
  for document in values(documents)
    if document.owner is owner && bufloaded(document.bufnr)
      add(snapshots, Capture(document.bufnr))
    endif
  endfor
  return snapshots
enddef

export def ProjectIsCurrent(snapshots: list<dict<any>>): bool
  return indexof(snapshots, (_, snapshot) => !IsCurrent(snapshot)) < 0
enddef

defcompile
