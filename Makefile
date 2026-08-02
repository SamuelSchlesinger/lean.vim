.PHONY: test test-live lint license-check hooks

test: license-check
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_abbreviations.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_backoff.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_completion.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_editor.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_indent.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_infoview_lifecycle.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_inlayhints.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_plugin.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_progress.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_request_queue.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_runtime_lifecycle.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_full_sync.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_stale_imports.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_util.vim

test-live:
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_live.vim

lint:
	vim -Nu NONE -i NONE -n -es -V1 -S test/lint.vim

license-check:
	sh test/check_licenses.sh

hooks:
	git config core.hooksPath .githooks
