.PHONY: test test-live lint license-check

test: license-check
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_plugin.vim
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_full_sync.vim

test-live:
	vim -Nu NONE -i NONE -n -es -V1 -S test/test_live.vim

lint:
	vim -Nu NONE -i NONE -n -es -V1 --cmd 'set runtimepath^=$(CURDIR)' \
		-c 'runtime plugin/lean.vim' \
		-c 'source autoload/lean/util.vim' \
		-c 'source autoload/lean/config.vim' \
		-c 'source autoload/lean/lsp.vim' \
		-c 'source autoload/lean/infoview.vim' \
		-c 'source autoload/lean/abbreviations.vim' \
		-c 'source autoload/lean/editor.vim' \
		-c 'source indent/lean.vim' \
		-c 'qa!'

license-check:
	sh test/check_licenses.sh
