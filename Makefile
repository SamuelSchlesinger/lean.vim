.PHONY: test test-live lint license-check hooks

OFFLINE_TESTS := $(filter-out test/test_live.vim,$(sort $(wildcard test/test_*.vim)))

test: license-check
	@for lean_test_script in $(OFFLINE_TESTS); do \
		python3 test/run_vim.py "$$lean_test_script" || exit $$?; \
	done

test-live:
	python3 test/run_vim.py test/test_live.vim

lint:
	python3 test/check_architecture.py
	python3 test/run_vim.py test/lint.vim

license-check:
	sh test/check_licenses.sh

hooks:
	git config core.hooksPath .githooks
