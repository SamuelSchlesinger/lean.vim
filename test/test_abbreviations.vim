vim9script

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
g:lean_config = {
  abbreviations: {extra: {zzz: '☃'}},
  infoview: {autoopen: false},
  lsp: {enable: false},
  semantic_highlighting: {enable: false},
}

runtime plugin/lean.vim
filetype plugin indent on

def NewLeanBuffer(initial: string = '')
  enew!
  setfiletype lean
  setline(1, initial)
  cursor(1, 1)
enddef

def Insert(keys: string)
  feedkeys(keys .. "\<Esc>", 'xt')
enddef

# Match lean.nvim's explicit delimiter behavior.
NewLeanBuffer()
Insert("i\\e ")
assert_equal(['ε '], getline(1, '$'), 'Space did not expand and remain after the abbreviation')

NewLeanBuffer()
Insert("i\\e\<Tab>")
assert_equal(['ε'], getline(1, '$'), 'Tab did not expand without inserting text')

NewLeanBuffer()
Insert("i\\e\<CR>")
assert_equal(['ε', ''], getline(1, '$'), 'Return did not expand before inserting a newline')

# $CURSOR must govern where subsequent text is inserted while delimiters keep
# their own position relative to the completed replacement.
NewLeanBuffer()
Insert("i\\<>\<Tab>abc")
assert_equal(['⟨abc⟩'], getline(1, '$'), 'Tab ignored the $CURSOR marker')

NewLeanBuffer()
Insert("i\\<> x")
assert_equal(['⟨x⟩ '], getline(1, '$'), 'Space moved inside the $CURSOR replacement')

NewLeanBuffer()
Insert("i\\<>\<CR>x")
assert_equal(['⟨', 'x⟩'], getline(1, '$'), 'Return was not inserted at $CURSOR')

# Punctuation after the insert cursor must never become part of the tracked
# abbreviation or be duplicated by a delimiter mapping.
NewLeanBuffer('foo bar baz,')
normal! $
Insert("i \\comp\<Tab> spam")
assert_equal(['foo bar baz ∘ spam,'], getline(1, '$'), 'mid-line Tab consumed punctuation')

NewLeanBuffer('foo bar baz,')
normal! $
Insert("i \\comp\<CR>spam")
assert_equal(['foo bar baz ∘', 'spam,'], getline(1, '$'), 'mid-line Return duplicated punctuation')

NewLeanBuffer('foo bar baz,')
normal! $
Insert("i \\comp ")
assert_equal(['foo bar baz ∘ ,'], getline(1, '$'), 'mid-line Space consumed punctuation')

# Delimiter handling is synchronous, including when several complete
# abbreviations are already queued in typeahead.
NewLeanBuffer()
Insert("i\\r \\r ")
assert_equal(['→ → '], getline(1, '$'), 'rapid Space expansions raced')

NewLeanBuffer()
Insert("i\\r\<Tab>\\r\<Tab>")
assert_equal(['→→'], getline(1, '$'), 'rapid Tab expansions raced')

NewLeanBuffer()
Insert("i\\r\<CR>\\r\<CR>")
assert_equal(['→', '→', ''], getline(1, '$'), 'rapid Return expansions raced')

NewLeanBuffer()
Insert("i\\\\ \\\\ ")
assert_equal(["\\ \\ "], getline(1, '$'), 'rapid escaped leaders raced')

# Deleting the mark, moving away from it, and starting a new abbreviation
# must cancel or restart the tracked range instead of converting stale text.
NewLeanBuffer()
Insert("i\\\<BS>x\\r ")
assert_equal(['x→ '], getline(1, '$'), 'deleting the leader left stale abbreviation state')

NewLeanBuffer()
inoremap <buffer> <Tab> TAB_SENTINEL
Insert("i\\r\<Left>x\<Tab>")
assert_equal(['\xTAB_SENTINELr'], getline(1, '$'), 'editing away from the range did not cancel it')

# All temporary mappings are overlays and cleanup is idempotent. Exercise
# Space as well as the two mappings inherited from lean.nvim's implementation.
NewLeanBuffer()
inoremap <buffer> <Space> SPACE_SENTINEL
inoremap <buffer> <Tab> TAB_SENTINEL
inoremap <buffer> <CR> CR_SENTINEL
var maps_before = {
  space: maparg('<Space>', 'i', false, true),
  tab: maparg('<Tab>', 'i', false, true),
  cr: maparg('<CR>', 'i', false, true),
}
Insert("i\\r ")
assert_equal(maps_before.space, maparg('<Space>', 'i', false, true), 'Space mapping was not restored')
assert_equal(maps_before.tab, maparg('<Tab>', 'i', false, true), 'Tab mapping was not restored')
assert_equal(maps_before.cr, maparg('<CR>', 'i', false, true), 'Return mapping was not restored')
Insert('A ')
assert_equal(['→ SPACE_SENTINEL'], getline(1, '$'), 'restored Space mapping did not execute')
Insert("A\<Tab>")
assert_equal(['→ SPACE_SENTINELTAB_SENTINEL'], getline(1, '$'), 'restored Tab mapping did not execute')
Insert("A\<CR>")
assert_equal(['→ SPACE_SENTINELTAB_SENTINELCR_SENTINEL'], getline(1, '$'),
  'restored Return mapping did not execute')

# A second cleanup event must not remove mappings restored by the first.
Insert("A\\r\<Esc>")
assert_equal(maps_before.space, maparg('<Space>', 'i', false, true),
  'repeated cleanup removed the restored Space mapping')
assert_equal(maps_before.tab, maparg('<Tab>', 'i', false, true),
  'repeated cleanup removed the restored Tab mapping')
assert_equal(maps_before.cr, maparg('<CR>', 'i', false, true),
  'repeated cleanup removed the restored Return mapping')

# Without a buffer-local mapping, removing the overlay must expose the same
# global mapping rather than creating an orphan buffer-local copy.
NewLeanBuffer()
inoremap <Tab> GLOBAL_TAB_SENTINEL
var global_tab = maparg('<Tab>', 'i', false, true)
Insert("i\\r\<Tab>")
assert_equal(global_tab, maparg('<Tab>', 'i', false, true), 'global Tab mapping changed')
assert_equal(0, get(maparg('<Tab>', 'i', false, true), 'buffer', -1),
  'temporary Tab mapping left a buffer-local orphan')
iunmap <Tab>

# InsertLeave is a conversion trigger and the whole edit remains one undo.
NewLeanBuffer()
Insert("i\\zzz")
assert_equal(['☃'], getline(1, '$'), 'InsertLeave did not expand an extra abbreviation')
undo
assert_equal([''], getline(1, '$'), 'Tab/leave conversion required more than one undo')

NewLeanBuffer()
Insert("i\\r ")
assert_equal(['→ '], getline(1, '$'))
undo
assert_equal([''], getline(1, '$'), 'Space conversion required more than one undo')

NewLeanBuffer()
Insert("i\\r\<CR>")
assert_equal(['→', ''], getline(1, '$'))
undo
assert_equal(['', ''], getline(1, '$'), 'Return conversion required more than one undo')

# Command-window support follows the Lean buffer that opened it.
NewLeanBuffer('foo → bar')
normal! $
feedkeys("q/a\\r \<CR>", 'xt')
assert_equal('→ ', @/, 'command-window abbreviation did not expand')

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  cquit
endif
qa!
