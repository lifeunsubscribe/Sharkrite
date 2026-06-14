# Sharkrite - Makefile for linting and testing
.PHONY: check shellcheck lint test help

# Optional subdirectory filter for the test target.
# Usage: make test FILTER=concurrency   → runs tests/concurrency/
#        make test FILTER=security      → runs tests/security/
#        make test                      → runs all tests under tests/
FILTER ?=

# Default target
help:
	@echo "Sharkrite Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  make check               - Run all linters (shellcheck + custom rules)"
	@echo "  make shellcheck          - Run shellcheck on all shell scripts"
	@echo "  make lint                - Run custom lint rules"
	@echo "  make test                - Run all bats tests (if available)"
	@echo "  make test FILTER=<name>  - Run tests under tests/<name>/ only"
	@echo "  make help                - Show this help message"

# Run all checks
check: shellcheck lint

# Run shellcheck on all shell scripts
shellcheck:
	@echo "Running shellcheck..."
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "ERROR: shellcheck not installed. Install with: brew install shellcheck"; \
		exit 1; \
	fi
	@find bin lib tools -type f \( -name "*.sh" -o -path "bin/rite*" -o -path "tools/git-hooks/*" \) -exec shellcheck --severity=warning {} +

# Run custom lint rules
lint:
	@echo "Running custom lint rules..."
	@./tools/sharkrite-lint.sh

# Run tests (if bats is available).
# When FILTER is set, restrict to tests/$(FILTER)/; otherwise run tests/.
# Uses --formatter pretty when the installed bats supports --report-formatter
# (bats-core >= 1.5); falls back to plain TAP on older versions.
test:
	@if command -v bats >/dev/null 2>&1; then \
		if grep -q -- '--report-formatter' "$$(command -v bats)" 2>/dev/null; then \
			_bats_fmt="-F pretty"; \
		else \
			_bats_fmt=""; \
		fi; \
		if [ -n "$(FILTER)" ]; then \
			if [ -d "tests/$(FILTER)" ]; then \
				echo "Running bats tests (filter: $(FILTER))..."; \
				bats $$_bats_fmt -r "tests/$(FILTER)/"; \
			else \
				echo "ERROR: tests/$(FILTER)/ not found"; \
				exit 1; \
			fi; \
		else \
			echo "Running bats tests..."; \
			bats $$_bats_fmt -r tests/; \
		fi; \
	else \
		echo "WARN: bats not installed. Skipping tests. Install with: brew install bats-core"; \
	fi
