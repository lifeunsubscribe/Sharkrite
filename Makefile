# Sharkrite - Makefile for linting and testing
.PHONY: check shellcheck lint test help

# Default target
help:
	@echo "Sharkrite Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  make check      - Run all linters (shellcheck + custom rules)"
	@echo "  make shellcheck - Run shellcheck on all shell scripts"
	@echo "  make lint       - Run custom lint rules"
	@echo "  make test       - Run bats tests (if available)"
	@echo "  make help       - Show this help message"

# Run all checks
check: shellcheck lint

# Run shellcheck on all shell scripts
shellcheck:
	@echo "Running shellcheck..."
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "ERROR: shellcheck not installed. Install with: brew install shellcheck"; \
		exit 1; \
	fi
	@find bin lib tools -type f \( -name "*.sh" -o -path "bin/rite*" -o -path "tools/git-hooks/*" \) -exec shellcheck {} +

# Run custom lint rules
lint:
	@echo "Running custom lint rules..."
	@./tools/sharkrite-lint.sh

# Run tests (if bats is available)
test:
	@if command -v bats >/dev/null 2>&1; then \
		echo "Running bats tests..."; \
		bats tests/; \
	else \
		echo "WARN: bats not installed. Skipping tests. Install with: brew install bats-core"; \
	fi
