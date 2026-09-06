vim9script

# Errors while sourcing a test must exit, rather than strand headless Vim in
# Ex mode. Individual scripts still own assertions and successful shutdown.
try
  execute 'source ' .. fnameescape($LEAN_VIM_TEST_SCRIPT)
catch
  echomsg v:throwpoint
  echomsg v:exception
  cquit
endtry
echomsg 'test returned without explicitly exiting: ' .. $LEAN_VIM_TEST_SCRIPT
cquit
