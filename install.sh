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

echo ""
echo "  Run 'rite --help' for usage information."
echo ""
