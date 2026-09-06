.PHONY: test test-live lint license-check hooks

test: license-check
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_abbreviations.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_backoff.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_completion.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_editor.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_indent.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_infoview_lifecycle.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_inlayhints.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_plugin.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_progress.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_request_queue.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_request_sync.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_runtime_lifecycle.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_full_sync.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_stale_imports.vim < /dev/null
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_util.vim < /dev/null

test-live:
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_live.vim < /dev/null

lint:
	vim -Nu NONE -i NONE -n -es -V1 -S test/lint.vim < /dev/null

license-check:
	sh test/check_licenses.sh

hooks:
	git config core.hooksPath .githooks
