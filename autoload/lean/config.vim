vim9script

import autoload 'lean/util.vim' as util

const DEFAULTS: dict<any> = {
  mappings: false,
  abbreviations: {
    enable: true,
    leader: "\\",
    extra: {},
  },
  completion: {
    enable: true,
    autotrigger: true,
    debounce: 100,
    min_length: 1,
    set_completeopt: true,
    resolve: true,
    timeout: 10000,
  },
  inlay_hints: {
    enable: true,
    debounce: 150,
    margin: 50,
    update_in_insert: false,
  },
  infoview: {
    autoopen: true,
    orientation: 'auto',
    width: 50,
    height: 12,
    update_cooldown: 50,
    show_processing: true,
    show_no_info: false,
    no_goals_text: 'Goals accomplished 🎉',
  },
  loogle: {
    enable: false,
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
    links: {},
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
    var user_infoview = get(user_config, 'infoview', {})
    # update_delay was the name used by the first Vim9 release. Keep it as an
    # alias while matching lean.nvim's update_cooldown option going forward.
    if has_key(user_infoview, 'update_delay')
        && !has_key(user_infoview, 'update_cooldown')
      cached.infoview.update_cooldown = user_infoview.update_delay
    endif
  endif
  return cached
enddef

export def Reset()
  cached = {}
enddef

defcompile
