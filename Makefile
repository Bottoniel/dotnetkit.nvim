.PHONY: test

# Needs plenary.nvim: found in the lazy.nvim data dir, or pass PLENARY_DIR=...
# One file only: make test TESTS=tests/dap_spec.lua
TESTS ?= tests/

test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory $(TESTS) { minimal_init = 'tests/minimal_init.lua' }"
