# Sharkrite Test Suite

Behavioral testing for Sharkrite using [bats-core](https://bats-core.readthedocs.io/).

## Quick Start

```bash
# Install bats-core
brew install bats-core  # macOS
# or
sudo apt-get install bats  # Ubuntu/Debian

# Run all tests
make test

# Run specific test file
bats tests/smoke/source-all-libs.bats

# Run specific test by name pattern
bats tests/ --filter "detect_pr"
```

## Test Structure

```
tests/
├── helpers/              # Test helpers (shared utilities)
│   ├── setup.bash       # Common setup (load in every test)
│   ├── git-fixtures.bash    # Git repo fixtures
│   ├── gh-mock.bash     # GitHub CLI mock
│   └── claude-mock.bash # Claude CLI mock
├── fixtures/            # Mock data (JSON/JSONL responses)
│   ├── gh/              # GitHub API responses
│   └── claude/          # Claude streaming responses
├── smoke/               # Smoke tests (basic sanity checks)
├── unit/                # Unit tests (isolated functions)
├── integration/         # Integration tests (multi-component)
├── regression/          # Regression tests (specific bug fixes)
├── security/            # Security-focused tests
└── README.md            # This file
```

## Test Patterns

### 1. Pure Helper Test (No External Dependencies)

**Example:** `tests/smoke/source-all-libs.bats`

Tests pure bash logic, utility functions, or syntax validation.

```bash
#!/usr/bin/env bats
load '../helpers/setup'

setup() {
  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

@test "my pure function works" {
  load_lib utils/my-utils.sh

  result=$(my_pure_function "input")
  [ "$result" = "expected output" ]
}
```

### 2. Git Interaction Test

**Example:** `tests/unit/pr-detection.bats`

Tests functions that interact with git repositories.

```bash
#!/usr/bin/env bats
load '../helpers/setup'
load '../helpers/git-fixtures'

setup() {
  setup_test_tmpdir

  # Create bare remote and fixture repo
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")
  cd "$FIXTURE_REPO"
}

teardown() {
  teardown_test_tmpdir
}

@test "branch creation works" {
  add_fixture_branch "test-branch"

  current=$(git branch --show-current)
  [ "$current" = "test-branch" ]
}
```

### 3. GitHub CLI Interaction Test

**Example:** `tests/integration/gh-workflow.bats`

Tests functions that call `gh` CLI.

```bash
#!/usr/bin/env bats
load '../helpers/setup'
load '../helpers/gh-mock'

setup() {
  setup_test_tmpdir
  export GH_MOCK_FIXTURE_DIR="${RITE_TEST_TMPDIR}/gh-fixtures"
  mkdir -p "$GH_MOCK_FIXTURE_DIR"
  reset_gh_mock
}

teardown() {
  teardown_test_tmpdir
}

@test "PR detection with gh mock" {
  # Create fixture
  cat > "${GH_MOCK_FIXTURE_DIR}/pr-view-123.json" <<'EOF'
{"number": 123, "title": "Test PR", "state": "OPEN"}
EOF

  # Override gh command
  gh() { mock_gh "$@"; }
  export -f gh
  export -f mock_gh

  # Test your function
  run mock_gh pr view 123
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"number": 123'
}
```

### 4. Claude Interaction Test

**Example:** `tests/integration/claude-workflow.bats`

Tests functions that call Claude CLI.

```bash
#!/usr/bin/env bats
load '../helpers/setup'
load '../helpers/claude-mock'

setup() {
  setup_test_tmpdir
  export CLAUDE_MOCK_FIXTURE_DIR="${RITE_TEST_TMPDIR}/claude-fixtures"
  mkdir -p "$CLAUDE_MOCK_FIXTURE_DIR"
  reset_claude_mock
}

teardown() {
  teardown_test_tmpdir
}

@test "claude session with mock" {
  # Create fixture with helper
  create_claude_fixture "test" "I fixed the bug."

  claude() { mock_claude "$@"; }
  export -f claude
  export -f mock_claude

  run mock_claude --scenario test
  [ "$status" -eq 0 ]
}
```

### 5. Full Phase Integration Test

**Example:** `tests/integration/full-phase.bats`

Tests complete workflows (git + gh + claude).

```bash
#!/usr/bin/env bats
load '../helpers/setup'
load '../helpers/git-fixtures'
load '../helpers/gh-mock'

setup() {
  setup_test_tmpdir

  BARE_REMOTE=$(create_bare_remote)
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")
  cd "$FIXTURE_REPO"

  export GH_MOCK_FIXTURE_DIR="${RITE_TEST_TMPDIR}/gh-fixtures"
  mkdir -p "$GH_MOCK_FIXTURE_DIR"
}

teardown() {
  teardown_test_tmpdir
}

@test "full workflow: branch → commit → PR" {
  # Create PR with fixture helper
  branch_name=$(add_fixture_pr 42 "Fix bug" 2)

  # Verify commits
  commit_count=$(git rev-list --count HEAD ^main)
  [ "$commit_count" -eq 2 ]
}
```

## Helper Functions

### Common Setup (`tests/helpers/setup.bash`)

- `setup_test_tmpdir()` - Creates unique temp directory
- `teardown_test_tmpdir()` - Cleans up temp directory
- `load_lib <path>` - Load a sharkrite library file
- `load_helper <name>` - Load a test helper
- `RITE_REPO_ROOT` - Path to sharkrite repo root
- `RITE_TEST_TMPDIR` - Unique temp directory for this test

### Git Fixtures (`tests/helpers/git-fixtures.bash`)

- `create_bare_remote [name]` - Create bare git repo (fake remote)
- `create_fixture_repo [remote_url]` - Create initialized git repo
- `add_fixture_commit "message" [file] [content]` - Add commit
- `add_fixture_branch "name" [base]` - Create branch
- `add_fixture_pr ISSUE# "title" [commits]` - Create PR simulation
- `add_fixture_issue ISSUE# "title" "body"` - Create issue metadata
- `create_divergence NUM` - Simulate branch divergence

### GitHub Mock (`tests/helpers/gh-mock.bash`)

- `mock_gh [args...]` - Mock gh CLI command
- `reset_gh_mock()` - Reset mock state
- `create_gh_fixture "name" '{"json": "..."}'` - Create fixture file

**Fixture naming:**
- `pr-view-123.json` - `gh pr view 123`
- `pr-list-default.json` - `gh pr list` (default fallback)
- `issue-view-42.json` - `gh issue view 42`
- `api-pulls-123.json` - `gh api repos/.../pulls/123`

**Fault injection:**
```bash
export GH_MOCK_FAIL_NTH=2      # Fail on 2nd call
export GH_MOCK_EXIT_CODE=1     # Exit code on failure
```

### Claude Mock (`tests/helpers/claude-mock.bash`)

- `mock_claude [args...]` - Mock claude CLI command
- `extract_claude_text` - Extract text from JSONL stream
- `create_claude_fixture "scenario" "text"` - Create JSONL fixture
- `reset_claude_mock()` - Reset mock state

**Fixture format (JSONL):**
```jsonl
{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"word "}}
{"type":"content_block_stop","index":0}
```

**Options:**
```bash
export CLAUDE_MOCK_EXIT_CODE=1  # Exit code to return
export CLAUDE_MOCK_DELAY=0.1    # Delay between lines (simulate streaming)
```

## Adding New Tests

1. **Choose test type:**
   - Smoke: Basic sanity (sourcing, syntax)
   - Unit: Single function/component
   - Integration: Multiple components
   - Regression: Specific bug fix

2. **Create test file:**
   ```bash
   touch tests/unit/my-new-test.bats
   chmod +x tests/unit/my-new-test.bats
   ```

3. **Write test:**
   ```bash
   #!/usr/bin/env bats
   load '../helpers/setup'

   setup() {
     setup_test_tmpdir
     # ... setup code
   }

   teardown() {
     teardown_test_tmpdir
   }

   @test "description of what you're testing" {
     # Test code here
     [ "$result" = "expected" ]
   }
   ```

4. **Run test:**
   ```bash
   bats tests/unit/my-new-test.bats
   ```

## Adding Fixtures

### GitHub Fixture

```bash
cat > tests/fixtures/gh/pr-view-456.json <<'EOF'
{
  "number": 456,
  "title": "My PR",
  "state": "OPEN"
}
EOF
```

### Claude Fixture

```bash
# Option 1: Use helper
create_claude_fixture "my-scenario" "Response text here"

# Option 2: Manual JSONL
cat > tests/fixtures/claude/my-scenario.jsonl <<'EOF'
{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Response "}}
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"text."}}
{"type":"content_block_stop","index":0}
EOF
```

## Tips

- **Isolate tests:** Each test should be independent (use temp dirs)
- **Clean up:** Always use `teardown()` to clean up resources
- **Descriptive names:** Test names should describe the behavior being tested
- **Use fixtures:** Don't hardcode data in tests, use fixture files
- **Mock externals:** Always mock `gh`, `claude`, external APIs
- **Test edge cases:** Empty inputs, missing files, API failures
- **Keep tests fast:** Avoid unnecessary delays or network calls

## CI Integration

Tests run automatically on every PR via `.github/workflows/lint.yml`:

```yaml
- name: Install bats
  run: sudo apt-get install -y bats

- name: Run all tests
  run: make test
```

## Debugging Tests

```bash
# Verbose output
bats -t tests/unit/my-test.bats

# Print output even on success
bats --verbose-run tests/unit/my-test.bats

# Run single test
bats tests/unit/my-test.bats --filter "specific test name"

# Keep temp directories for inspection
# (comment out teardown_test_tmpdir in teardown())
```

## Common Issues

**Issue:** `command not found: bats`
**Fix:** Install bats-core: `brew install bats-core`

**Issue:** Test fails with "unbound variable"
**Fix:** Check that all variables are initialized in setup() or use `${VAR:-default}` syntax

**Issue:** Fixture not found
**Fix:** Verify fixture path matches mock's expectation (check `GH_MOCK_FIXTURE_DIR` / `CLAUDE_MOCK_FIXTURE_DIR`)

**Issue:** Test passes locally but fails in CI
**Fix:** Check for missing dependencies (git config, env vars) in CI environment

## Resources

- [Bats Tutorial](https://bats-core.readthedocs.io/en/stable/tutorial.html)
- [Bats Writing Tests](https://bats-core.readthedocs.io/en/stable/writing-tests.html)
- [Bash Test Patterns](https://github.com/bats-core/bats-core#usage)
