vim9script

import autoload 'lean/util.vim' as util

const DEFAULTS: dict<any> = {
  mappings: false,
  abbreviations: {
    enable: true,
    leader: "\\",
    extra: {},
  },
  infoview: {
    autoopen: true,
    orientation: 'auto',
    width: 50,
    height: 12,
    update_delay: 80,
    show_processing: true,
    show_no_info: false,
  },
  lsp: {
    enable: true,
    command: [],
    change_delay: 50,
    root_markers: ['lakefile.toml', 'lakefile.lean', 'lean-toolchain', '.git'],
    stderr: true,
  },
  progress_bars: {
    enable: true,
    character: '│',
  },
  semantic_highlighting: {
    enable: true,
  },
  signs: {
    enable: true,
  },
}

var cached: dict<any> = {}

export def Get(): dict<any>
  if empty(cached)
    var user_config: dict<any> = get(g:, 'lean_config', {})
    cached = util.DeepMerge(DEFAULTS, user_config)
  endif
  return cached
enddef

export def Reset()
  cached = {}
enddef

defcompile
