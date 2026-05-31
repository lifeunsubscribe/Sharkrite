#!/usr/bin/env bash
# Git fixture helpers for bats tests
#
# Provides functions to create ephemeral git repositories with known state

# Create a bare git repo to serve as a fake remote
# Returns: path to the bare repo
create_bare_remote() {
  local remote_name="${1:-origin}"
  local bare_repo="${RITE_TEST_TMPDIR}/${remote_name}.git"

  git init --bare "$bare_repo" >/dev/null 2>&1 || {
    echo "ERROR: Failed to create bare repository at ${bare_repo}" >&2
    return 1
  }
  echo "$bare_repo"
}

# Create a fixture git repository with initial commit
# Usage: create_fixture_repo [remote_url]
# Returns: path to the fixture repo
create_fixture_repo() {
  local remote_url="${1:-}"
  local repo_dir="${RITE_TEST_TMPDIR}/fixture-repo"

  mkdir -p "$repo_dir"
  cd "$repo_dir" || {
    echo "ERROR: Failed to cd to ${repo_dir}" >&2
    return 1
  }

  # Initialize repo
  git init >/dev/null 2>&1 || {
    echo "ERROR: Failed to initialize git repository in ${repo_dir}" >&2
    return 1
  }
  git config user.name "Test User" || return 1
  git config user.email "test@example.com" || return 1

  # Create initial commit
  echo "# Test Repository" > README.md
  git add README.md || {
    echo "ERROR: Failed to git add README.md" >&2
    return 1
  }
  git commit -m "Initial commit" >/dev/null 2>&1 || {
    echo "ERROR: Failed to create initial commit" >&2
    return 1
  }

  # Set up remote if provided
  if [ -n "$remote_url" ]; then
    git remote add origin "$remote_url" || {
      echo "ERROR: Failed to add remote origin ${remote_url}" >&2
      return 1
    }
    git branch -M main || {
      echo "ERROR: Failed to rename branch to main" >&2
      return 1
    }
    git push -u origin main >/dev/null 2>&1 || {
      echo "ERROR: Failed to push to origin/main" >&2
      return 1
    }
  fi

  echo "$repo_dir"
}

# Add a commit to the current repo
# Usage: add_fixture_commit "commit message" [file_path] [file_content]
add_fixture_commit() {
  local message="$1"
  local file_path="${2:-changes.txt}"
  local file_content="${3:-Change at $(date +%s)}"

  echo "$file_content" > "$file_path"
  git add "$file_path" || {
    echo "ERROR: Failed to git add ${file_path}" >&2
    return 1
  }
  git commit -m "$message" >/dev/null 2>&1 || {
    echo "ERROR: Failed to commit with message: ${message}" >&2
    return 1
  }
}

# Create a feature branch
# Usage: add_fixture_branch "branch-name" [base_branch]
add_fixture_branch() {
  local branch_name="$1"
  local base_branch="${2:-main}"

  git checkout -b "$branch_name" "$base_branch" >/dev/null 2>&1 || {
    echo "ERROR: Failed to create branch ${branch_name} from ${base_branch}" >&2
    return 1
  }
}

# Create a PR simulation (branch + commits + push)
# Usage: add_fixture_pr ISSUE_NUMBER "pr title" [num_commits]
# Creates a branch like "fix/issue-description-#N" with commits
add_fixture_pr() {
  local issue_number="$1"
  local pr_title="$2"
  local num_commits="${3:-2}"

  # Create branch name from title (sanitize)
  local branch_name="fix/$(echo "$pr_title" | tr '[:upper:]' '[:lower:]' | tr -s ' ' '-' | tr -cd '[:alnum:]-')-#${issue_number}"

  # Create and checkout branch
  add_fixture_branch "$branch_name" "main" || return 1

  # Add commits
  for i in $(seq 1 "$num_commits"); do
    add_fixture_commit "Work on issue #${issue_number} - commit $i" \
      "work-${i}.txt" \
      "Progress on: ${pr_title}" || {
      echo "ERROR: Failed to create commit $i for issue #${issue_number}" >&2
      return 1
    }
  done

  # Push to remote if origin exists
  if git remote get-url origin >/dev/null 2>&1; then
    git push -u origin "$branch_name" >/dev/null 2>&1 || {
      echo "ERROR: Failed to push branch ${branch_name} to origin" >&2
      return 1
    }
  fi

  echo "$branch_name"
}

# Create a GitHub issue simulation (metadata only, no actual API call)
# Usage: add_fixture_issue ISSUE_NUMBER "issue title" "issue body"
# Creates a JSON file in .git/rite-test-issues/ for mock gh CLI to read
add_fixture_issue() {
  local issue_number="$1"
  local issue_title="$2"
  local issue_body="$3"

  local issues_dir=".git/rite-test-issues"
  mkdir -p "$issues_dir"

  cat > "${issues_dir}/${issue_number}.json" <<EOF
{
  "number": ${issue_number},
  "title": "${issue_title}",
  "body": "${issue_body}",
  "state": "open",
  "labels": []
}
EOF

  echo "${issues_dir}/${issue_number}.json"
}

# Simulate divergence between branch and main
# Usage: create_divergence NUM_COMMITS_BEHIND
# Adds commits to main while on feature branch
create_divergence() {
  local num_commits="${1:-5}"
  local current_branch
  current_branch=$(git branch --show-current)

  # Switch to main and add commits
  git checkout main >/dev/null 2>&1 || {
    echo "ERROR: Failed to checkout main branch" >&2
    return 1
  }
  for i in $(seq 1 "$num_commits"); do
    add_fixture_commit "Main branch commit $i" "main-work-${i}.txt" || {
      echo "ERROR: Failed to create divergence commit $i" >&2
      return 1
    }
  done

  # Push main if remote exists
  if git remote get-url origin >/dev/null 2>&1; then
    git push origin main >/dev/null 2>&1 || {
      echo "ERROR: Failed to push main divergence commits to origin" >&2
      return 1
    }
  fi

  # Return to feature branch
  git checkout "$current_branch" >/dev/null 2>&1 || {
    echo "ERROR: Failed to return to branch ${current_branch}" >&2
    return 1
  }
}
