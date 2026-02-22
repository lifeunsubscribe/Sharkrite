#!/usr/bin/env bash
# install.sh - Install Sharkrite CLI
# Idempotent: safe to run multiple times (updates existing installation)
#
# Installation layout:
#   ~/.rite/           - Sharkrite runtime (lib/, templates/, config/)
#   ~/.local/bin/rite  - Symlink to bin/rite (or custom location)
#   ~/.config/rite/    - User configuration (preserved on update)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

# Resolve source directory (where this install.sh lives)
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Installation targets
INSTALL_DIR="$HOME/.rite"
CONFIG_DIR="$HOME/.config/rite"
BIN_DIR="${RITE_BIN_DIR:-$HOME/.local/bin}"

print_header "Sharkrite Installer"

# =============================================================================
# Step 1: Check Dependencies
# =============================================================================

echo "Checking dependencies..."

MISSING_DEPS=()

if ! command -v git &>/dev/null; then
  MISSING_DEPS+=("git")
fi

if ! command -v gh &>/dev/null; then
  MISSING_DEPS+=("gh (GitHub CLI) - brew install gh")
fi

if ! command -v jq &>/dev/null; then
  MISSING_DEPS+=("jq - brew install jq")
fi

if ! command -v claude &>/dev/null; then
  MISSING_DEPS+=("claude (Claude CLI) - npm install -g @anthropic-ai/claude-code")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
  print_warning "Missing dependencies:"
  for dep in "${MISSING_DEPS[@]}"; do
    echo "  - $dep"
  done
  echo ""
  read -p "Continue anyway? (y/N): " CONTINUE
  if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
    echo "Install cancelled. Install missing dependencies and try again."
    exit 1
  fi
else
  print_success "All dependencies found"
fi

# Check bash version (batch processing requires bash 4+ for associative arrays)
BASH_MAJOR="${BASH_VERSINFO[0]}"
if [ "$BASH_MAJOR" -lt 4 ]; then
  print_warning "System bash is version $BASH_VERSION (bash 4+ required for batch processing)"

  # Check if a newer bash exists at common Homebrew locations
  NEWER_BASH=""
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$candidate" ]; then
      CANDIDATE_VER=$("$candidate" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo "0")
      if [ "$CANDIDATE_VER" -ge 4 ]; then
        NEWER_BASH="$candidate"
        break
      fi
    fi
  done

  if [ -n "$NEWER_BASH" ]; then
    print_success "Found bash 4+ at $NEWER_BASH"
    print_info "Ensure $(dirname "$NEWER_BASH") is before /bin in your PATH"
  elif command -v brew &>/dev/null; then
    echo ""
    read -p "Install bash 4+ via Homebrew? (Y/n): " INSTALL_BASH
    if [[ ! "$INSTALL_BASH" =~ ^[Nn]$ ]]; then
      echo "Installing bash via Homebrew..."
      brew install bash
      BREW_BASH="$(brew --prefix)/bin/bash"
      if [ -x "$BREW_BASH" ]; then
        print_success "Bash installed: $BREW_BASH"
        print_info "Ensure $(brew --prefix)/bin is before /bin in your PATH"
      fi
    fi
  else
    print_warning "Homebrew not found. Install bash 4+ manually:"
    echo "  1. Install Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    echo "  2. brew install bash"
    echo "  3. Add /opt/homebrew/bin to your PATH before /bin"
  fi
else
  print_success "Bash $BASH_VERSION (4+ requirement met)"
fi

# =============================================================================
# Step 2: Detect Existing Installation
# =============================================================================

if [ -d "$INSTALL_DIR" ]; then
  print_info "Existing Sharkrite installation detected at $INSTALL_DIR"
  print_info "Updating... (your configs in $CONFIG_DIR will be preserved)"
  echo ""
  IS_UPDATE=true
else
  IS_UPDATE=false
fi

# =============================================================================
# Step 3: Create Installation Directory
# =============================================================================

echo "Installing Sharkrite to $INSTALL_DIR..."

mkdir -p "$INSTALL_DIR"

# Copy lib/ (runtime scripts)
rm -rf "$INSTALL_DIR/lib"
cp -R "$SOURCE_DIR/lib" "$INSTALL_DIR/lib"

# Copy bin/
rm -rf "$INSTALL_DIR/bin"
cp -R "$SOURCE_DIR/bin" "$INSTALL_DIR/bin"

# Copy templates/
rm -rf "$INSTALL_DIR/templates"
cp -R "$SOURCE_DIR/templates" "$INSTALL_DIR/templates"

# Copy config examples/
rm -rf "$INSTALL_DIR/config"
cp -R "$SOURCE_DIR/config" "$INSTALL_DIR/config"

# Make all scripts executable
find "$INSTALL_DIR" -name "*.sh" -exec chmod +x {} \;
chmod +x "$INSTALL_DIR/bin/rite"

print_success "Runtime installed to $INSTALL_DIR"

# =============================================================================
# Step 4: Create Config Directory (preserve existing)
# =============================================================================

mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/config" ]; then
  cp "$SOURCE_DIR/config/rite.conf.example" "$CONFIG_DIR/config"
  print_success "Created global config: $CONFIG_DIR/config"
else
  print_info "Global config preserved: $CONFIG_DIR/config"
fi

# =============================================================================
# Step 5: Create Symlink in PATH
# =============================================================================

mkdir -p "$BIN_DIR"

# Remove old symlink if it exists
if [ -L "$BIN_DIR/rite" ]; then
  rm "$BIN_DIR/rite"
fi

ln -sf "$INSTALL_DIR/bin/rite" "$BIN_DIR/rite"
print_success "Symlink created: $BIN_DIR/rite -> $INSTALL_DIR/bin/rite"

# Check if BIN_DIR is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "^${BIN_DIR}$"; then
  print_warning "$BIN_DIR is not in your PATH"
  echo ""
  echo "  Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
  echo ""
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
  NEEDS_PATH_UPDATE=true
else
  NEEDS_PATH_UPDATE=false
fi

# =============================================================================
# Step 6: Verify Installation
# =============================================================================

echo ""
print_header "Installation Complete"

if [ "$IS_UPDATE" = true ]; then
  print_success "Sharkrite updated successfully"
else
  print_success "Sharkrite installed successfully"
fi

echo ""
echo "  Installation:  $INSTALL_DIR"
echo "  Config:        $CONFIG_DIR/config"
echo "  Binary:        $BIN_DIR/rite"
echo ""

if [ "$NEEDS_PATH_UPDATE" = true ]; then
  echo "  Next steps:"
  echo "    1. Add $BIN_DIR to your PATH (see above)"
  echo "    2. Restart your shell or run: source ~/.zshrc"
  echo "    3. cd into a git repo and run: rite --init"
  echo "    4. Process your first issue: rite 21"
else
  echo "  Next steps:"
  echo "    1. cd into a git repo and run: rite --init"
  echo "    2. Edit .rite/config with project-specific settings"
  echo "    3. Process your first issue: rite 21"
fi

# Verify bash 4+ is reachable in PATH
ENV_BASH=$(command -v bash 2>/dev/null || echo "/bin/bash")
ENV_BASH_VER=$("$ENV_BASH" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo "0")
if [ "$ENV_BASH_VER" -lt 4 ]; then
  echo ""
  print_warning "bash in PATH ($ENV_BASH) is still version $("$ENV_BASH" --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  print_info "Batch processing (rite --label, multi-issue) requires bash 4+"
  BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")
  echo "  Add to your shell profile (~/.zshrc or ~/.bashrc):"
  echo ""
  echo "    export PATH=\"${BREW_PREFIX}/bin:\$PATH\""
  echo ""
fi

echo ""
echo "  Run 'rite --help' for usage information."
echo ""
