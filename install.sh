#!/usr/bin/env bash
set -euo pipefail

# Ultimate Bug Scanner - Installation Script
# https://github.com/Dicklesworthstone/ultimate_bug_scanner

VERSION="4.5"

# Validate bash version (requires 4.0+)
if ((BASH_VERSINFO[0] < 4)); then
  echo "Error: This installer requires Bash 4.0 or later (you have $BASH_VERSION)" >&2
  echo "Please upgrade bash or install manually." >&2
  exit 1
fi
SCRIPT_NAME="ubs"
INSTALL_NAME="ubs"
REPO_URL="https://raw.githubusercontent.com/Dicklesworthstone/ultimate_bug_scanner/main"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

# Symbols
CHECK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
ARROW="${BLUE}→${RESET}"
WARN="${YELLOW}⚠${RESET}"

# Flags
NON_INTERACTIVE=0
EASY_MODE=0
SKIP_AST_GREP=0
SKIP_RIPGREP=0
SKIP_JQ=0
SKIP_HOOKS=0
INSTALL_DIR=""
FORCE_REINSTALL=0
SKIP_VERSION_CHECK=0
RUN_VERIFICATION=1

# Temporary files tracking for cleanup
TEMP_FILES=()
# Lock file for concurrent execution prevention (MUST be fixed name, not $$)
LOCK_FILE="/tmp/ubs-install.lock"
# Track if we own the lock (only remove it if we created it)
LOCK_OWNED=0

cleanup_on_exit() {
  # Clean up temporary files
  if [ ${#TEMP_FILES[@]} -gt 0 ]; then
    for temp_file in "${TEMP_FILES[@]}"; do
      rm -rf "$temp_file" 2>/dev/null
    done
  fi
  # Clean up common temp files from this script
  rm -f /tmp/ast-grep-install.log /tmp/jq-install.log /tmp/ripgrep-install.log 2>/dev/null
  rm -f /tmp/download-error.log /tmp/sed-error.log /tmp/bug-scan.txt 2>/dev/null
  rm -rf /tmp/ripgrep.tar.gz /tmp/ripgrep-* /tmp/ast-grep.zip /tmp/ast-grep 2>/dev/null
  # Remove lock file ONLY if we created it (don't remove another process's lock!)
  if [ "$LOCK_OWNED" -eq 1 ]; then
    rmdir "$LOCK_FILE" 2>/dev/null || true  # || true prevents set -e from killing cleanup
    LOCK_OWNED=0  # Mark that we no longer own it (prevents double-remove in EXIT trap)
  fi
}

# Set up cleanup traps
# For INT/TERM: cleanup then exit immediately (don't continue script)
# For EXIT: just cleanup (already exiting)
trap 'cleanup_on_exit; exit 130' INT   # 130 = 128 + SIGINT (2)
trap 'cleanup_on_exit; exit 143' TERM  # 143 = 128 + SIGTERM (15)
trap cleanup_on_exit EXIT

print_header() {
  echo -e "${BOLD}${BLUE}"
  cat << 'HEADER'
    ╔══════════════════════════════════════════════════════════════════╗
    ║                                                                  ║
    ║     ██╗   ██╗██████╗ ███████╗    ██╗███╗   ██╗███████╗████████╗ ║
    ║     ██║   ██║██╔══██╗██╔════╝    ██║████╗  ██║██╔════╝╚══██╔══╝ ║
    ║     ██║   ██║██████╔╝███████╗    ██║██╔██╗ ██║███████╗   ██║    ║
    ║     ██║   ██║██╔══██╗╚════██║    ██║██║╚██╗██║╚════██║   ██║    ║
    ║     ╚██████╔╝██████╔╝███████║    ██║██║ ╚████║███████║   ██║    ║
    ║      ╚═════╝ ╚═════╝ ╚══════╝    ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝    ║
    ║                                                                  ║
HEADER
  echo -e "    ║         ${GREEN}🔬 ULTIMATE BUG SCANNER INSTALLER v${VERSION} 🔬${BLUE}         ║"
  cat << 'HEADER'
    ║                                                                  ║
    ║   Industrial-Grade Static Analysis for Polyglot AI Codebases    ║
    ║              Catch 1000+ Bug Patterns Before Production         ║
    ║                                                                  ║
    ╚══════════════════════════════════════════════════════════════════╝
HEADER
  echo -e "${RESET}"
}

log() { echo -e "${ARROW} $*"; }
success() { echo -e "${CHECK} $*"; }
error() { echo -e "${CROSS} $*" >&2; }
warn() { echo -e "${WARN} $*"; }

ask() {
  local prompt="$1"
  if [ "$EASY_MODE" -eq 1 ]; then
    log "Easy mode: auto-accepting prompt -> ${prompt}"
    return 0
  fi
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    return 1  # Default to "no" in non-interactive mode
  fi
  local response
  read -p "$(echo -e "${YELLOW}?${RESET} ${prompt} (y/N): ")" response
  [[ "$response" =~ ^[Yy]$ ]]
}

can_use_sudo() {
  # Check if sudo is available and can be used without password prompt
  if ! command -v sudo >/dev/null 2>&1; then
    return 1
  fi
  # Check if we can run sudo -n (non-interactive)
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  # If interactive mode, we can potentially use sudo with password
  if [ "$NON_INTERACTIVE" -eq 0 ]; then
    return 0
  fi
  return 1
}

safe_timeout() {
  # Cross-platform timeout wrapper
  # Usage: safe_timeout <seconds> <command> [args...]
  # Returns: command exit code, or 124 if timeout occurred
  local timeout_duration="$1"
  shift

  # Try GNU timeout first (Linux, some BSD with coreutils)
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_duration" "$@"
    return $?
  fi

  # Try gtimeout (macOS with coreutils via brew)
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_duration" "$@"
    return $?
  fi

  # Fallback: bash-based timeout implementation for macOS/BSD
  # This works on systems without GNU timeout/gtimeout
  "$@" &
  local pid=$!

  # Wait for process with timeout
  local count=0
  while kill -0 $pid 2>/dev/null; do
    if [ $count -ge "$timeout_duration" ]; then
      kill -TERM $pid 2>/dev/null
      sleep 1
      kill -KILL $pid 2>/dev/null
      wait $pid 2>/dev/null
      return 124  # Standard timeout exit code
    fi
    sleep 1
    ((count++))
  done

  # Get actual exit status
  wait $pid
  return $?
}

detect_platform() {
  local os
  os="$(uname -s)"

  # WSL detection (uname shows Linux, but /proc/version mentions Microsoft)
  if [[ "$os" == "Linux" ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    echo "wsl"
    return 0
  fi

  case "$os" in
    Linux*)   echo "linux" ;;
    Darwin*)  echo "macos" ;;
    FreeBSD*) echo "freebsd" ;;
    OpenBSD*) echo "openbsd" ;;
    NetBSD*)  echo "netbsd" ;;
    CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
    *)        echo "unknown" ;;
  esac
}

detect_shell() {
  if [ -n "${BASH_VERSION:-}" ]; then
    echo "bash"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    echo "zsh"
  else
    # Check default shell
    basename "$SHELL"
  fi
}

get_rc_file() {
  local shell_type
  shell_type="$(detect_shell)"
  case "$shell_type" in
    bash)
      if [ -f "$HOME/.bashrc" ]; then
        echo "$HOME/.bashrc"
      else
        echo "$HOME/.bash_profile"
      fi
      ;;
    zsh)
      echo "$HOME/.zshrc"
      ;;
    *)
      echo "$HOME/.profile"
      ;;
  esac
}

check_ast_grep() {
  if command -v ast-grep >/dev/null 2>&1 || command -v sg >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

install_ast_grep() {
  local platform
  platform="$(detect_platform)"

  log "Installing ast-grep..."

  case "$platform" in
    macos)
      if command -v brew >/dev/null 2>&1; then
        if brew install ast-grep 2>&1 | tee /tmp/ast-grep-install.log; then
          success "ast-grep installed via Homebrew"
          return 0
        else
          error "Homebrew installation failed. Check /tmp/ast-grep-install.log"
          return 1
        fi
      else
        error "Homebrew not found. Please install from: https://ast-grep.github.io/guide/quick-start.html"
        return 1
      fi
      ;;
    wsl|linux)
      # WSL and Linux use same package managers
      if [ "$platform" = "wsl" ]; then
        log "Detected WSL environment - using Linux package managers"
      fi
      # Try package managers with proper error handling
      if command -v cargo >/dev/null 2>&1; then
        log "Attempting installation via cargo..."
        if cargo install ast-grep 2>&1 | tee /tmp/ast-grep-install.log; then
          success "ast-grep installed via cargo"
          return 0
        else
          warn "Cargo installation failed, trying npm..."
        fi
      fi

      if command -v npm >/dev/null 2>&1; then
        log "Attempting installation via npm..."
        if npm install -g @ast-grep/cli 2>&1 | tee /tmp/ast-grep-install.log; then
          success "ast-grep installed via npm"
          return 0
        else
          warn "npm installation failed"
        fi
      fi

      warn "Package managers failed. Trying binary download..."
      if download_binary_release "ast-grep" "$platform"; then
        return 0
      fi

      error "All installation methods failed"
      log "Download manually from: https://github.com/ast-grep/ast-grep/releases"
      return 1
      ;;
    freebsd|openbsd|netbsd)
      log "BSD platform detected: $platform"
      # Try cargo first
      if command -v cargo >/dev/null 2>&1; then
        log "Attempting installation via cargo..."
        if cargo install ast-grep 2>&1 | tee /tmp/ast-grep-install.log; then
          success "ast-grep installed via cargo"
          return 0
        fi
      fi

      # Try npm
      if command -v npm >/dev/null 2>&1; then
        log "Attempting installation via npm..."
        if npm install -g @ast-grep/cli 2>&1 | tee /tmp/ast-grep-install.log; then
          success "ast-grep installed via npm"
          return 0
        fi
      fi

      # Try binary download
      warn "Package managers failed. Trying binary download..."
      if download_binary_release "ast-grep" "$platform"; then
        return 0
      fi

      error "All installation methods failed for BSD"
      log "Download manually from: https://github.com/ast-grep/ast-grep/releases"
      return 1
      ;;
    windows)
      if command -v cargo >/dev/null 2>&1; then
        if cargo install ast-grep 2>&1 | tee /tmp/ast-grep-install.log; then
          success "ast-grep installed via cargo"
          return 0
        else
          error "Cargo installation failed"
          return 1
        fi
      else
        warn "Install Rust/Cargo or download from: https://ast-grep.github.io/"
        return 1
      fi
      ;;
    *)
      error "Unknown platform. Install manually from: https://ast-grep.github.io/"
      return 1
      ;;
  esac

  # Final verification
  if check_ast_grep; then
    success "ast-grep installed successfully"
    return 0
  else
    error "ast-grep installation failed - command not found after install"
    return 1
  fi
}

check_ripgrep() {
  if command -v rg >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

check_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# ==============================================================================
# TIER 1 ENHANCEMENTS: Version Checking, Binary Fallbacks, Verification
# ==============================================================================

version_compare() {
  # Compare two version strings using semantic versioning
  # Returns: 0 if $1 > $2, 1 if $1 <= $2
  # Handles versions like: 4.5, 4.10, 4.9.1, 4.9.10, etc.
  local ver1="$1"
  local ver2="$2"

  # If versions are identical, not greater
  if [ "$ver1" = "$ver2" ]; then
    return 1
  fi

  # Try sort -V (version sort) - but test it properly first
  if echo "2.0" | sort -V >/dev/null 2>&1; then
    # sort -V is available, use it
    local sorted_first
    sorted_first=$(printf '%s\n' "$ver1" "$ver2" | sort -V | head -n1)
    if [ "$sorted_first" = "$ver2" ]; then
      return 0  # ver1 > ver2
    else
      return 1  # ver1 <= ver2
    fi
  else
    # Fallback: manual comparison for simple X.Y.Z versions
    IFS='.' read -r -a v1_parts <<< "$ver1"
    IFS='.' read -r -a v2_parts <<< "$ver2"

    # Compare each component
    local max_len="${#v1_parts[@]}"
    [ "${#v2_parts[@]}" -gt "$max_len" ] && max_len="${#v2_parts[@]}"

    for ((i=0; i<max_len; i++)); do
      local part1="${v1_parts[i]:-0}"
      local part2="${v2_parts[i]:-0}"

      if [ "$part1" -gt "$part2" ] 2>/dev/null; then
        return 0  # ver1 > ver2
      elif [ "$part1" -lt "$part2" ] 2>/dev/null; then
        return 1  # ver1 < ver2
      fi
    done

    return 1  # versions are equal
  fi
}

check_for_updates() {
  [ "$SKIP_VERSION_CHECK" -eq 1 ] && return 0

  local current_version="$VERSION"
  local latest_url="$REPO_URL/VERSION"

  log "Checking for updates..."
  local latest_version
  if latest_version=$(curl -fsSL --max-time 5 "$latest_url" 2>/dev/null); then
    # Strip whitespace
    latest_version=$(echo "$latest_version" | tr -d '[:space:]')

    # Compare versions properly using semantic versioning
    if version_compare "$latest_version" "$current_version"; then
      warn "New version available: $latest_version (you have $current_version)"
      if ask "Update to latest version now?"; then
        log "Re-running installer with latest version..."
        # Clean up lock before exec (exec replaces process, so trap won't fire)
        # CRITICAL: Set LOCK_OWNED=0 BEFORE rmdir to prevent signal race condition
        # (If signal arrives after rmdir but before LOCK_OWNED=0, trap would try to
        #  remove lock that might have been acquired by another process!)
        LOCK_OWNED=0  # Mark that we no longer own the lock
        rmdir "$LOCK_FILE" 2>/dev/null || true  # Remove it (|| true prevents set -e from aborting)
        exec bash <(curl -fsSL "$REPO_URL/install.sh") "${ORIGINAL_ARGS[@]}"
        # If we get here, exec failed - abort immediately (we no longer have the lock!)
        error "Failed to download or execute updated installer"
        exit 1
      fi
    else
      success "You have the latest version ($current_version)"
    fi
  else
    warn "Could not check for updates (network issue or rate limit)"
  fi
}

download_binary_release() {
  local tool="$1"  # ast-grep, ripgrep, or jq
  local platform="$2"
  local arch

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    armv7*) arch="armv7" ;;
    *) error "Unsupported architecture: $arch"; return 1 ;;
  esac

  local install_dir="$HOME/.local/bin"
  mkdir -p "$install_dir" 2>/dev/null || { error "Cannot create $install_dir"; return 1; }

  log "Attempting binary download for $tool ($platform-$arch)..."

  case "$tool" in
    ripgrep)
      local version="14.1.0"
      local asset tarball_dir
      case "$platform" in
        linux|wsl)
          asset="ripgrep-${version}-${arch}-unknown-linux-musl.tar.gz"
          tarball_dir="ripgrep-${version}-${arch}-unknown-linux-musl"
          ;;
        macos)
          asset="ripgrep-${version}-${arch}-apple-darwin.tar.gz"
          tarball_dir="ripgrep-${version}-${arch}-apple-darwin"
          ;;
        freebsd)
          asset="ripgrep-${version}-${arch}-unknown-freebsd.tar.gz"
          tarball_dir="ripgrep-${version}-${arch}-unknown-freebsd"
          ;;
        *) warn "No binary release for $platform"; return 1 ;;
      esac

      local url="https://github.com/BurntSushi/ripgrep/releases/download/${version}/${asset}"

      if curl -fsSL "$url" -o /tmp/ripgrep.tar.gz 2>/dev/null; then
        if tar -xzf /tmp/ripgrep.tar.gz -C /tmp 2>/dev/null; then
          # Find rg binary robustly (handles archive structure changes)
          local rg_binary
          rg_binary=$(find /tmp/ripgrep-* -name "rg" -type f 2>/dev/null | head -1)
          if [ -n "$rg_binary" ] && [ -f "$rg_binary" ]; then
            chmod +x "$rg_binary" 2>/dev/null
            mv "$rg_binary" "$install_dir/rg"
            rm -rf /tmp/ripgrep.tar.gz /tmp/ripgrep-* 2>/dev/null
            success "ripgrep binary installed to $install_dir/rg"
            return 0
          else
            warn "Could not find rg binary in downloaded archive"
          fi
        fi
      fi
      rm -rf /tmp/ripgrep.tar.gz /tmp/ripgrep-* 2>/dev/null
      ;;

    ast-grep)
      local version="0.18.0"
      local asset
      case "$platform-$arch" in
        linux-x86_64|wsl-x86_64) asset="ast-grep-x86_64-unknown-linux-gnu.zip" ;;
        linux-aarch64|wsl-aarch64) asset="ast-grep-aarch64-unknown-linux-gnu.zip" ;;
        macos-x86_64) asset="ast-grep-x86_64-apple-darwin.zip" ;;
        macos-aarch64) asset="ast-grep-aarch64-apple-darwin.zip" ;;
        *) warn "No binary release for $platform-$arch"; return 1 ;;
      esac

      local url="https://github.com/ast-grep/ast-grep/releases/download/${version}/${asset}"

      if curl -fsSL "$url" -o /tmp/ast-grep.zip 2>/dev/null; then
        if command -v unzip >/dev/null 2>&1; then
          if unzip -q /tmp/ast-grep.zip -d /tmp/ast-grep 2>/dev/null; then
            # Find ast-grep binary robustly (handles archive structure changes)
            local sg_binary
            sg_binary=$(find /tmp/ast-grep \( -name "ast-grep" -o -name "sg" \) -type f 2>/dev/null | head -1)
            if [ -n "$sg_binary" ] && [ -f "$sg_binary" ]; then
              chmod +x "$sg_binary" 2>/dev/null
              mv "$sg_binary" "$install_dir/ast-grep"
              rm -rf /tmp/ast-grep.zip /tmp/ast-grep
              success "ast-grep binary installed to $install_dir/ast-grep"
              # Ensure $install_dir is in PATH for this session
              export PATH="$install_dir:$PATH"
              return 0
            else
              warn "Could not find ast-grep binary in downloaded archive"
            fi
          fi
        else
          warn "unzip not available, cannot extract ast-grep"
        fi
      fi
      rm -rf /tmp/ast-grep.zip /tmp/ast-grep 2>/dev/null
      ;;

    jq)
      local version="1.7.1"
      local asset
      case "$platform-$arch" in
        linux-x86_64|wsl-x86_64) asset="jq-linux-amd64" ;;
        linux-aarch64|wsl-aarch64) asset="jq-linux-arm64" ;;
        macos-x86_64|macos-aarch64) asset="jq-macos-amd64" ;;
        *) warn "No binary release for $platform-$arch"; return 1 ;;
      esac

      local url="https://github.com/jqlang/jq/releases/download/jq-${version}/${asset}"

      if curl -fsSL "$url" -o "$install_dir/jq" 2>/dev/null; then
        chmod +x "$install_dir/jq"
        success "jq binary installed to $install_dir/jq"
        # Ensure $install_dir is in PATH for this session
        export PATH="$install_dir:$PATH"
        return 0
      fi
      ;;
  esac

  error "Binary download failed for $tool"
  return 1
}

verify_installation() {
  [ "$RUN_VERIFICATION" -eq 0 ] && return 0

  log "Running post-install verification..."
  local errors=0

  echo ""
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${BLUE}   POST-INSTALL VERIFICATION${RESET}"
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
  echo ""

  # Test 1: Command available
  if command -v ubs >/dev/null 2>&1; then
    success "ubs command available in PATH"
    log "   Location: $(command -v ubs)"
  else
    error "ubs command not found in PATH"
    ((errors++))
  fi

  # Test 2: Can execute --help
  if ubs --help >/dev/null 2>&1 || ubs -h >/dev/null 2>&1; then
    success "ubs executes successfully"
  else
    error "ubs command fails to run"
    ((errors++))
  fi

  # Test 3: Dependencies
  echo ""
  log "Dependency check:"
  if check_ast_grep; then
    success "   ast-grep: $(command -v ast-grep || command -v sg)"
  else
    warn "   ast-grep: not available (scanner will use regex mode only)"
  fi

  if check_ripgrep; then
    success "   ripgrep: $(command -v rg)"
  else
    warn "   ripgrep: not available (will fallback to grep)"
  fi

  if check_jq; then
    success "   jq: $(command -v jq)"
  else
    warn "   jq: not available (JSON/SARIF merging disabled)"
  fi

  # Test 4: Quick smoke test
  echo ""
  log "Running smoke test..."
  local test_file="/tmp/ubs-test-$$.js"
  cat > "$test_file" << 'SMOKE'
// Intentional bugs for smoke test
eval(userInput);
const x = null;
x.foo();
SMOKE

  if safe_timeout 10 ubs "$test_file" --ci 2>&1 | grep -q "eval\|null"; then
    success "Smoke test PASSED - scanner detects bugs correctly"
    rm -f "$test_file"
  else
    warn "Smoke test inconclusive - scanner may not be fully functional"
    rm -f "$test_file"
  fi

  # Test 5: Module cache directory
  echo ""
  local module_dir="${XDG_DATA_HOME:-$HOME/.local/share}/ubs/modules"
  if mkdir -p "$module_dir" 2>/dev/null && [ -w "$module_dir" ]; then
    success "Module cache directory writable: $module_dir"
  else
    warn "Module cache directory not writable - modules cannot be cached"
  fi

  # Test 6: Hooks
  echo ""
  log "Integration hooks:"
  [ -f ".git/hooks/pre-commit" ] && grep -q "ubs" ".git/hooks/pre-commit" 2>/dev/null && \
    success "   Git pre-commit hook installed" || \
    log "   Git hook: not installed"

  [ -f ".claude/hooks/on-file-write.sh" ] && \
    success "   Claude Code hook installed" || \
    log "   Claude hook: not installed"

  echo ""
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"

  if [ $errors -eq 0 ]; then
    echo ""
    success "${BOLD}All verification checks passed! ✓${RESET}"
    echo ""
    return 0
  else
    echo ""
    error "$errors critical verification checks failed"
    warn "Installation may be incomplete. Review errors above."
    echo ""
    return 1
  fi
}

# ==============================================================================
# TIER 2 ENHANCEMENTS: Configuration, Diagnostics, Uninstall, More AI Tools
# ==============================================================================

normalize_bool() {
  # Convert various boolean representations to 0 or 1
  # Returns: 0 (false) or 1 (true), defaults to 0 for invalid values
  local val="$1"
  val=$(echo "$val" | tr '[:upper:]' '[:lower:]')  # Convert to lowercase

  case "$val" in
    1|yes|true|on|enabled|enable) echo "1" ;;
    0|no|false|off|disabled|disable|"") echo "0" ;;
    *)
      warn "Invalid boolean value '$1' in config file, treating as 0 (false)"
      echo "0"
      ;;
  esac
}

read_config_file() {
  local config_file="${XDG_CONFIG_HOME:-$HOME/.config}/ubs/install.conf"

  if [ ! -f "$config_file" ]; then
    return 0
  fi

  log "Reading configuration from $config_file..."

  # Simple key=value format parser with validation
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue

    # Trim whitespace
    key=$(echo "$key" | tr -d '[:space:]')
    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    case "$key" in
      install_dir)
        INSTALL_DIR="$value"
        ;;
      skip_ast_grep)
        SKIP_AST_GREP="$(normalize_bool "$value")"
        ;;
      skip_ripgrep)
        SKIP_RIPGREP="$(normalize_bool "$value")"
        ;;
      skip_jq)
        SKIP_JQ="$(normalize_bool "$value")"
        ;;
      skip_hooks)
        SKIP_HOOKS="$(normalize_bool "$value")"
        ;;
      skip_version_check)
        SKIP_VERSION_CHECK="$(normalize_bool "$value")"
        ;;
      easy_mode)
        local normalized="$(normalize_bool "$value")"
        EASY_MODE="$normalized"
        NON_INTERACTIVE="$normalized"
        ;;
      non_interactive)
        NON_INTERACTIVE="$(normalize_bool "$value")"
        ;;
      *)
        warn "Unknown config key '$key' in $config_file (ignored)"
        ;;
    esac
  done < "$config_file"

  success "Loaded configuration from $config_file"
}

generate_config() {
  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ubs"
  local config_file="$config_dir/install.conf"

  mkdir -p "$config_dir" 2>/dev/null || {
    error "Cannot create config directory: $config_dir"
    return 1
  }

  if [ -f "$config_file" ]; then
    warn "Config file already exists: $config_file"
    if ! ask "Overwrite existing configuration?"; then
      log "Keeping existing configuration"
      return 0
    fi
    cp "$config_file" "${config_file}.backup"
    log "Backed up existing config to ${config_file}.backup"
  fi

  cat > "$config_file" << 'CONFIG'
# Ultimate Bug Scanner Installation Configuration
# This file controls default behavior of install.sh
# Values: 0 = false/no, 1 = true/yes

# Installation directory (default: auto-detect ~/.local/bin or /usr/local/bin)
# Uncomment and set to customize:
# install_dir=/usr/local/bin

# Skip dependency installations (1=skip, 0=install if missing)
skip_ast_grep=0
skip_ripgrep=0
skip_jq=0

# Skip version checking on install
skip_version_check=0

# Skip hook/integration setup (1=skip, 0=prompt or install in easy mode)
skip_hooks=0

# Easy mode: auto-accept all prompts and install everything (1=yes, 0=no)
easy_mode=0

# Non-interactive mode: skip all prompts, use defaults (1=yes, 0=no)
non_interactive=0
CONFIG

  success "Created configuration file: $config_file"
  log "Edit this file to customize future installations"
  log "Settings in this file will be used as defaults"

  if ask "Open config file in editor now?"; then
    local editor="${EDITOR:-${VISUAL:-nano}}"
    if command -v "$editor" >/dev/null 2>&1; then
      "$editor" "$config_file"
    else
      log "Set \$EDITOR environment variable to use your preferred editor"
      log "File location: $config_file"
    fi
  fi

  return 0
}

diagnostic_check() {
  echo ""
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${BLUE}   ULTIMATE BUG SCANNER DIAGNOSTIC REPORT${RESET}"
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
  echo ""

  # System info
  echo -e "${BOLD}System Information:${RESET}"
  echo "  OS: $(uname -s) $(uname -r)"
  echo "  Platform: $(detect_platform)"
  echo "  Architecture: $(uname -m)"
  echo "  Shell: $(detect_shell) ($SHELL)"
  echo "  Bash Version: $BASH_VERSION"
  echo ""

  # UBS installation
  echo -e "${BOLD}UBS Installation:${RESET}"
  if command -v ubs >/dev/null 2>&1; then
    success "  ubs command available"
    echo "  Location: $(command -v ubs)"

    # Try to get version
    local ubs_version
    if ubs_version=$(ubs --version 2>/dev/null | head -n1); then
      echo "  Version: $ubs_version"
    elif ubs --help 2>&1 | head -n5 | grep -i version >/dev/null; then
      echo "  Version: $(ubs --help 2>&1 | grep -i version | head -n1)"
    else
      echo "  Version: unknown"
    fi

    if safe_timeout 5 ubs --help >/dev/null 2>&1; then
      success "  ubs runs successfully"
    else
      error "  ubs fails to execute"
    fi
  else
    error "  ubs command not found"
  fi
  echo ""

  # Dependencies
  echo -e "${BOLD}Dependencies:${RESET}"
  for dep in ast-grep sg rg jq; do
    if command -v "$dep" >/dev/null 2>&1; then
      success "  $dep: $(command -v $dep)"
    else
      warn "  $dep: not found"
    fi
  done
  echo ""

  # PATH analysis
  echo -e "${BOLD}PATH Entries (relevant):${RESET}"
  local IFS=':'
  for p in $PATH; do
    if [[ "$p" == *".local/bin"* ]] || [[ "$p" == *"/usr/local/bin"* ]] || [[ "$p" == *"ubs"* ]]; then
      if [ -d "$p" ]; then
        echo "  ✓ $p"
      else
        warn "  ✗ $p (directory doesn't exist)"
      fi
    fi
  done
  echo ""

  # Integration Hooks
  echo -e "${BOLD}Integration Hooks:${RESET}"
  [ -f ".git/hooks/pre-commit" ] && grep -q "ubs" ".git/hooks/pre-commit" 2>/dev/null && \
    success "  Git pre-commit hook installed" || \
    log "  Git hook: not installed"

  [ -f ".claude/hooks/on-file-write.sh" ] && \
    success "  Claude Code hook installed" || \
    log "  Claude hook: not installed"

  [ -f ".cursor/rules" ] && grep -q "Ultimate Bug Scanner" ".cursor/rules" 2>/dev/null && \
    success "  Cursor rules configured" || \
    log "  Cursor: not configured"

  [ -f ".codex/rules" ] && grep -q "Ultimate Bug Scanner" ".codex/rules" 2>/dev/null && \
    success "  Codex CLI rules configured" || \
    log "  Codex: not configured"

  [ -f ".gemini/rules" ] && grep -q "Ultimate Bug Scanner" ".gemini/rules" 2>/dev/null && \
    success "  Gemini rules configured" || \
    log "  Gemini: not configured"

  echo ""

  # Module cache
  local module_dir="${XDG_DATA_HOME:-$HOME/.local/share}/ubs/modules"
  echo -e "${BOLD}Module Cache:${RESET}"
  if [ -d "$module_dir" ]; then
    echo "  Location: $module_dir"
    if [ "$(ls -1 "$module_dir" 2>/dev/null | wc -l)" -gt 0 ]; then
      echo "  Cached modules:"
      ls -1 "$module_dir" 2>/dev/null | sed 's/^/    - /'
    else
      log "  (No modules cached yet)"
    fi
  else
    log "  Module directory not created yet"
    if mkdir -p "$module_dir" 2>/dev/null; then
      success "  Created module directory: $module_dir"
    else
      warn "  Cannot create module directory"
    fi
  fi
  echo ""

  # Test network connectivity
  echo -e "${BOLD}Network Connectivity:${RESET}"
  if safe_timeout 5 curl -fsSL --max-time 5 "https://api.github.com" >/dev/null 2>&1; then
    success "  Can reach GitHub API"
  else
    warn "  Cannot reach GitHub (check network/firewall)"
  fi
  echo ""

  # Permissions
  echo -e "${BOLD}Permissions:${RESET}"
  local install_dir="$(determine_install_dir)"
  if [ -w "$install_dir" ]; then
    success "  Install directory writable: $install_dir"
  else
    warn "  Install directory not writable: $install_dir"
  fi

  local rc_file="$(get_rc_file)"
  if [ -w "$rc_file" ]; then
    success "  RC file writable: $rc_file"
  else
    warn "  RC file not writable: $rc_file"
  fi
  echo ""

  # Configuration
  local config_file="${XDG_CONFIG_HOME:-$HOME/.config}/ubs/install.conf"
  echo -e "${BOLD}Configuration:${RESET}"
  if [ -f "$config_file" ]; then
    success "  Config file exists: $config_file"
  else
    log "  No config file (run with --generate-config to create)"
  fi
  echo ""

  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
  echo ""
  echo -e "${BOLD}💡 To share this diagnostic report:${RESET}"
  echo "   Run: curl -fsSL ... | bash -s -- --diagnose > ubs-diagnostic.txt"
  echo "   Then attach ubs-diagnostic.txt to your issue report"
  echo ""
}

uninstall_ubs() {
  echo ""
  echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${YELLOW}   UNINSTALL ULTIMATE BUG SCANNER${RESET}"
  echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════${RESET}"
  echo ""

  warn "This will remove Ultimate Bug Scanner and all integrations"
  if ! ask "Continue with uninstall?"; then
    log "Uninstall cancelled"
    return 0
  fi

  log "Uninstalling Ultimate Bug Scanner..."
  echo ""

  # Remove binary
  local install_dir="$(determine_install_dir)"
  local script_path="$install_dir/$INSTALL_NAME"

  if [ -f "$script_path" ]; then
    rm -f "$script_path"
    success "Removed binary: $script_path"
  else
    log "Binary not found at: $script_path"
  fi

  # Remove from PATH (restore RC file)
  local rc_file="$(get_rc_file)"
  if [ -f "$rc_file" ]; then
    if grep -q "Ultimate Bug Scanner" "$rc_file" 2>/dev/null; then
      # Backup before modifying
      cp "$rc_file" "${rc_file}.pre-uninstall-backup"
      log "Backed up $rc_file to ${rc_file}.pre-uninstall-backup"

      # Remove PATH and alias entries (blank line + comment line + export line)
      # First remove the comment and export lines
      sed -i.bak '/# Ultimate Bug Scanner.*added/,+1d' "$rc_file" 2>/dev/null && rm -f "${rc_file}.bak"
      # Then remove orphaned blank lines that might be left (up to 2)
      sed -i.bak '/^$/N;/^\n$/d' "$rc_file" 2>/dev/null && rm -f "${rc_file}.bak"
      success "Removed from $rc_file"
    fi
  fi

  # Remove hooks
  echo ""
  if ask "Remove git hooks?"; then
    if [ -f ".git/hooks/pre-commit" ] && grep -q "Ultimate Bug Scanner" ".git/hooks/pre-commit" 2>/dev/null; then
      if [ -f ".git/hooks/pre-commit.backup" ]; then
        mv ".git/hooks/pre-commit.backup" ".git/hooks/pre-commit"
        success "Restored backup git hook"
      else
        rm -f ".git/hooks/pre-commit"
        success "Removed git hook"
      fi
    fi
  fi

  if ask "Remove Claude Code hook?"; then
    if [ -f ".claude/hooks/on-file-write.sh" ]; then
      rm -f ".claude/hooks/on-file-write.sh"
      success "Removed Claude hook"
    fi
  fi

  if ask "Remove AI agent guardrails (.cursor/rules, etc.)?"; then
    for dir in .cursor .codex .gemini .windsurf .cline .opencode; do
      if [ -f "$dir/rules" ] && grep -q "Ultimate Bug Scanner" "$dir/rules" 2>/dev/null; then
        sed -i.bak '/# >>> Ultimate Bug Scanner/,/# <<< End Ultimate Bug Scanner/d' "$dir/rules" 2>/dev/null
        rm -f "$dir/rules.bak"
        success "Removed guardrails from $dir/rules"
      fi
    done
  fi

  # Remove module cache
  echo ""
  if ask "Remove cached modules?"; then
    local module_dir="${XDG_DATA_HOME:-$HOME/.local/share}/ubs"
    if [ -d "$module_dir" ]; then
      rm -rf "$module_dir"
      success "Removed module cache: $module_dir"
    fi
  fi

  # Remove configuration
  if ask "Remove configuration file?"; then
    local config_file="${XDG_CONFIG_HOME:-$HOME/.config}/ubs/install.conf"
    if [ -f "$config_file" ]; then
      rm -f "$config_file"
      success "Removed config file: $config_file"
    fi
  fi

  echo ""
  echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${GREEN}   UNINSTALL COMPLETE${RESET}"
  echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${RESET}"
  echo ""
  success "Ultimate Bug Scanner has been uninstalled"
  log "To reinstall: curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash"
  echo ""
}

install_jq() {
  local platform
  platform="$(detect_platform)"
  log "Installing jq..."
  case "$platform" in
    macos)
      if command -v brew >/dev/null 2>&1; then
        if brew install jq 2>&1 | tee /tmp/jq-install.log; then
          success "jq installed via Homebrew"; return 0
        else
          error "Homebrew installation failed. See /tmp/jq-install.log"; return 1
        fi
      else
        error "Homebrew not found. Install jq manually."; return 1
      fi
      ;;
    wsl|linux)
      if [ "$platform" = "wsl" ]; then
        log "Detected WSL environment - using Linux package managers"
      fi
      if command -v apt-get >/dev/null 2>&1 && can_use_sudo; then
        if safe_timeout 300 sudo apt-get update -qq && safe_timeout 300 sudo apt-get install -y jq 2>&1 | tee /tmp/jq-install.log; then
          success "jq installed via apt-get"; return 0
        fi
      fi
      if command -v dnf >/dev/null 2>&1 && can_use_sudo; then
        if safe_timeout 300 sudo dnf install -y jq 2>&1 | tee /tmp/jq-install.log; then
          success "jq installed via dnf"; return 0
        fi
      fi
      if command -v pacman >/dev/null 2>&1 && can_use_sudo; then
        if safe_timeout 300 sudo pacman -S --noconfirm jq 2>&1 | tee /tmp/jq-install.log; then
          success "jq installed via pacman"; return 0
        fi
      fi
      if command -v snap >/dev/null 2>&1 && can_use_sudo; then
        if safe_timeout 300 sudo snap install jq 2>&1 | tee /tmp/jq-install.log; then
          success "jq installed via snap"; return 0
        fi
      fi
      warn "Package managers failed. Trying binary download..."
      if download_binary_release "jq" "$platform"; then
        return 0
      fi
      error "All installation methods failed"
      log "Download manually from: https://stedolan.github.io/jq/"
      return 1
      ;;
    freebsd|openbsd|netbsd)
      log "BSD platform detected: $platform"
      if command -v pkg >/dev/null 2>&1 && can_use_sudo; then
        if safe_timeout 300 sudo pkg install -y jq 2>&1 | tee /tmp/jq-install.log; then
          success "jq installed via pkg"; return 0
        fi
      fi
      if command -v pkg_add >/dev/null 2>&1 && can_use_sudo; then
        if safe_timeout 300 sudo pkg_add jq 2>&1 | tee /tmp/jq-install.log; then
          success "jq installed via pkg_add"; return 0
        fi
      fi
      warn "Package managers failed. Trying binary download..."
      if download_binary_release "jq" "$platform"; then
        return 0
      fi
      error "All installation methods failed for BSD"
      log "Download manually from: https://stedolan.github.io/jq/"
      return 1
      ;;
    windows)
      warn "Install jq with scoop/choco or your preferred package manager"
      return 1
      ;;
    *)
      error "Unknown platform for jq install"; return 1
      ;;
  esac
}

install_ripgrep() {
  local platform
  platform="$(detect_platform)"

  log "Installing ripgrep..."

  case "$platform" in
    macos)
      if command -v brew >/dev/null 2>&1; then
        if brew install ripgrep 2>&1 | tee /tmp/ripgrep-install.log; then
          success "ripgrep installed via Homebrew"
          return 0
        else
          error "Homebrew installation failed. Check /tmp/ripgrep-install.log"
          return 1
        fi
      else
        error "Homebrew not found. Please install from: https://github.com/BurntSushi/ripgrep#installation"
        return 1
      fi
      ;;
    wsl|linux)
      # WSL and Linux use same package managers
      if [ "$platform" = "wsl" ]; then
        log "Detected WSL environment - using Linux package managers"
      fi
      # Try package managers with fallback chain
      if command -v cargo >/dev/null 2>&1; then
        log "Attempting installation via cargo..."
        if cargo install ripgrep 2>&1 | tee /tmp/ripgrep-install.log; then
          success "ripgrep installed via cargo"
          return 0
        else
          warn "Cargo installation failed, trying system package managers..."
        fi
      fi

      if command -v apt-get >/dev/null 2>&1; then
        if can_use_sudo; then
          log "Attempting installation via apt-get..."
          if safe_timeout 300 sudo apt-get update -qq && safe_timeout 300 sudo apt-get install -y ripgrep 2>&1 | tee /tmp/ripgrep-install.log; then
            success "ripgrep installed via apt-get"
            return 0
          else
            warn "apt-get installation failed, trying next method..."
          fi
        else
          warn "sudo not available or not configured, skipping apt-get..."
        fi
      fi

      if command -v dnf >/dev/null 2>&1; then
        if can_use_sudo; then
          log "Attempting installation via dnf..."
          if safe_timeout 300 sudo dnf install -y ripgrep 2>&1 | tee /tmp/ripgrep-install.log; then
            success "ripgrep installed via dnf"
            return 0
          else
            warn "dnf installation failed, trying next method..."
          fi
        else
          warn "sudo not available, skipping dnf..."
        fi
      fi

      if command -v pacman >/dev/null 2>&1; then
        if can_use_sudo; then
          log "Attempting installation via pacman..."
          if safe_timeout 300 sudo pacman -S --noconfirm ripgrep 2>&1 | tee /tmp/ripgrep-install.log; then
            success "ripgrep installed via pacman"
            return 0
          else
            warn "pacman installation failed, trying next method..."
          fi
        else
          warn "sudo not available, skipping pacman..."
        fi
      fi

      if command -v snap >/dev/null 2>&1; then
        if can_use_sudo; then
          log "Attempting installation via snap..."
          if safe_timeout 300 sudo snap install ripgrep --classic 2>&1 | tee /tmp/ripgrep-install.log; then
            success "ripgrep installed via snap"
            return 0
          else
            warn "snap installation failed"
          fi
        else
          warn "sudo not available, skipping snap..."
        fi
      fi

      warn "All package managers failed. Trying binary download..."
      if download_binary_release "ripgrep" "$platform"; then
        return 0
      fi

      error "All installation methods failed"
      log "Download manually from: https://github.com/BurntSushi/ripgrep/releases"
      return 1
      ;;
    freebsd|openbsd|netbsd)
      log "BSD platform detected: $platform"
      if command -v pkg >/dev/null 2>&1; then
        if can_use_sudo; then
          log "Attempting installation via pkg..."
          if safe_timeout 300 sudo pkg install -y ripgrep 2>&1 | tee /tmp/ripgrep-install.log; then
            success "ripgrep installed via pkg"
            return 0
          fi
        fi
      fi

      if command -v pkg_add >/dev/null 2>&1; then
        if can_use_sudo; then
          log "Attempting installation via pkg_add..."
          if safe_timeout 300 sudo pkg_add ripgrep 2>&1 | tee /tmp/ripgrep-install.log; then
            success "ripgrep installed via pkg_add"
            return 0
          fi
        fi
      fi

      # Try cargo as fallback
      if command -v cargo >/dev/null 2>&1; then
        log "Attempting installation via cargo..."
        if cargo install ripgrep 2>&1 | tee /tmp/ripgrep-install.log; then
          success "ripgrep installed via cargo"
          return 0
        fi
      fi

      # Try binary download
      warn "Package managers failed. Trying binary download..."
      if download_binary_release "ripgrep" "$platform"; then
        return 0
      fi

      error "All installation methods failed for BSD"
      log "Download manually from: https://github.com/BurntSushi/ripgrep/releases"
      return 1
      ;;
    windows)
      if command -v cargo >/dev/null 2>&1; then
        log "Attempting installation via cargo..."
        if cargo install ripgrep 2>&1 | tee /tmp/ripgrep-install.log; then
          success "ripgrep installed via cargo"
          return 0
        else
          warn "Cargo installation failed, trying Windows package managers..."
        fi
      fi

      if command -v scoop >/dev/null 2>&1; then
        log "Attempting installation via scoop..."
        if scoop install ripgrep 2>&1 | tee /tmp/ripgrep-install.log; then
          success "ripgrep installed via scoop"
          return 0
        else
          warn "scoop installation failed, trying choco..."
        fi
      fi

      if command -v choco >/dev/null 2>&1; then
        log "Attempting installation via chocolatey..."
        if choco install ripgrep 2>&1 | tee /tmp/ripgrep-install.log; then
          success "ripgrep installed via chocolatey"
          return 0
        else
          warn "chocolatey installation failed"
        fi
      fi

      warn "Install Rust/Cargo, Scoop, or Chocolatey"
      log "Download from: https://github.com/BurntSushi/ripgrep/releases"
      return 1
      ;;
    *)
      error "Unknown platform. Install manually from: https://github.com/BurntSushi/ripgrep#installation"
      return 1
      ;;
  esac

  # Final verification
  if check_ripgrep; then
    success "ripgrep installed successfully"
    return 0
  else
    error "ripgrep installation failed - command not found after install"
    return 1
  fi
}

validate_install_dir() {
  local dir="$1"

  # Security: Prevent installation to dangerous locations
  case "$dir" in
    /|/bin|/sbin|/usr/bin|/usr/sbin|/boot|/dev|/proc|/sys)
      error "Refusing to install to system directory: $dir"
      return 1
      ;;
    /*/../*|*/..|../*|*/../*)
      error "Invalid path (contains ..): $dir"
      return 1
      ;;
    ""|" "*|*" "*)
      error "Invalid path (empty or contains spaces): $dir"
      return 1
      ;;
  esac

  # Must be an absolute path
  if [[ "$dir" != /* ]]; then
    error "Installation directory must be an absolute path: $dir"
    return 1
  fi

  return 0
}

determine_install_dir() {
  if [ -n "$INSTALL_DIR" ]; then
    # Validate user-provided directory
    if ! validate_install_dir "$INSTALL_DIR"; then
      error "Invalid installation directory: $INSTALL_DIR"
      exit 1
    fi
    echo "$INSTALL_DIR"
    return
  fi

  # Prefer ~/.local/bin if it exists or can be created
  if [ -d "$HOME/.local/bin" ] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
    echo "$HOME/.local/bin"
  elif [ -w "/usr/local/bin" ]; then
    echo "/usr/local/bin"
  else
    echo "$HOME/.local/bin"
  fi
}

install_scanner() {
  local install_dir
  install_dir="$(determine_install_dir)"

  log "Installing Ultimate Bug Scanner to $install_dir..."

  # Create directory if needed
  mkdir -p "$install_dir" 2>/dev/null || {
    error "Cannot create directory: $install_dir"
    return 1
  }

  # Download or copy script
  local script_path="$install_dir/$INSTALL_NAME"
  local temp_path="${script_path}.tmp"

  if [ -f "./$SCRIPT_NAME" ]; then
    # Local installation
    log "Installing from local file..."
    if cp "./$SCRIPT_NAME" "$temp_path" 2>/dev/null; then
      # Verify it's a bash script
      if head -n 1 "$temp_path" | grep -q '^#!/.*bash'; then
        mv "$temp_path" "$script_path"
        success "Copied from local directory"
      else
        error "Local file doesn't appear to be a bash script"
        rm -f "$temp_path"
        return 1
      fi
    else
      error "Failed to copy local file"
      return 1
    fi
  else
    # Remote installation
    log "Downloading from GitHub..."
    local download_url="${REPO_URL}/${SCRIPT_NAME}"

    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL "$download_url" -o "$temp_path" 2>/tmp/download-error.log; then
        log "Downloaded successfully via curl"
      else
        error "Download failed. Check /tmp/download-error.log"
        rm -f "$temp_path"
        return 1
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -q "$download_url" -O "$temp_path" 2>/tmp/download-error.log; then
        log "Downloaded successfully via wget"
      else
        error "Download failed. Check /tmp/download-error.log"
        rm -f "$temp_path"
        return 1
      fi
    else
      error "Neither curl nor wget found. Cannot download script."
      return 1
    fi

    # Verify downloaded file
    if [ ! -s "$temp_path" ]; then
      error "Downloaded file is empty"
      rm -f "$temp_path"
      return 1
    fi

    # Check minimum file size (legitimate script should be >10KB)
    local file_size
    file_size=$(wc -c < "$temp_path" 2>/dev/null || echo "0")
    if [ "$file_size" -lt 10240 ]; then
      error "Downloaded file too small ($file_size bytes) - likely incomplete"
      rm -f "$temp_path"
      return 1
    fi

    # Verify shebang (strip UTF-8 BOM if present, then check for bash shebang)
    # Use octal escapes for BSD/macOS compatibility (\357\273\277 = 0xEF 0xBB 0xBF)
    local first_line
    first_line=$(head -n 1 "$temp_path" | sed 's/^\o357\o273\o277//' | tr -d '\r\n\t ' | head -c 50)
    if [[ ! "$first_line" =~ ^#!.*bash ]]; then
      error "Downloaded file doesn't appear to be a bash script"
      log "First line: $(head -n 1 "$temp_path" | cat -v)"
      rm -f "$temp_path"
      return 1
    fi

    # Verify critical content markers
    if ! grep -q "UBS Meta-Runner" "$temp_path"; then
      error "Downloaded file doesn't appear to be the UBS meta-runner"
      rm -f "$temp_path"
      return 1
    fi

    # Move to final location
    mv "$temp_path" "$script_path"
  fi

  # Make executable
  chmod +x "$script_path" 2>/dev/null || {
    error "Failed to make script executable"
    return 1
  }

  # Final verification
  if [ -x "$script_path" ] && [ -s "$script_path" ]; then
    success "Installed to: $script_path"

    # Verify it can run
    if "$script_path" --help >/dev/null 2>&1 || "$script_path" -h >/dev/null 2>&1; then
      success "Installation verified - script is functional"
      return 0
    else
      warn "Script installed but may not be fully functional"
      return 0
    fi
  else
    error "Installation failed - file not executable or empty"
    return 1
  fi
}

is_in_path() {
  local dir="$1"
  local normalized_dir

  # Normalize path (resolve symlinks, remove trailing slashes)
  if command -v realpath >/dev/null 2>&1; then
    normalized_dir=$(realpath -s "$dir" 2>/dev/null || echo "$dir")
  else
    normalized_dir="${dir%/}"  # Remove trailing slash
  fi

  # Check each PATH entry
  local IFS=':'
  for path_entry in $PATH; do
    local normalized_entry
    if command -v realpath >/dev/null 2>&1; then
      normalized_entry=$(realpath -s "$path_entry" 2>/dev/null || echo "$path_entry")
    else
      normalized_entry="${path_entry%/}"
    fi

    if [ "$normalized_dir" = "$normalized_entry" ]; then
      return 0
    fi
  done

  return 1
}

add_to_path() {
  local install_dir
  install_dir="$(determine_install_dir)"

  # Check if already in PATH (robust checking)
  if is_in_path "$install_dir"; then
    log "Directory already in PATH"
    return 0
  fi

  local rc_file
  rc_file="$(get_rc_file)"

  # Check if rc_file is writable
  if [ ! -w "$rc_file" ] && [ ! -w "$(dirname "$rc_file")" ]; then
    error "Cannot write to $rc_file - check permissions"
    return 1
  fi

  log "Adding $install_dir to PATH in $rc_file..."

  # Check if PATH entry already exists in file (use literal string match to avoid regex issues)
  if grep -qF "PATH=\"\$PATH:$install_dir\"" "$rc_file" 2>/dev/null || \
     grep -qF "PATH=\$PATH:$install_dir" "$rc_file" 2>/dev/null || \
     grep -qF "PATH=\"$install_dir:\$PATH\"" "$rc_file" 2>/dev/null || \
     grep -qF "PATH=$install_dir:\$PATH" "$rc_file" 2>/dev/null; then
    log "PATH entry already exists in $rc_file"
    return 0
  fi

  # Add PATH export
  {
    echo ""
    echo "# Ultimate Bug Scanner (added $(date +%Y-%m-%d))"
    echo "export PATH=\"\$PATH:$install_dir\""
  } >> "$rc_file"

  success "Added to PATH in $rc_file"
  warn "⚠ IMPORTANT: Restart your shell or run: source $rc_file"
  return 0
}

create_alias() {
  local install_dir
  install_dir="$(determine_install_dir)"
  local script_path="$install_dir/$INSTALL_NAME"

  # The binary is named 'ubs' and will be on PATH, but we also add an alias so
  # the current shell session can use it immediately without restarting.

  local rc_file
  rc_file="$(get_rc_file)"

  log "Configuring 'ubs' command..."

  # Check if ubs command is already available
  if command -v ubs >/dev/null 2>&1; then
    success "'ubs' command is already available"
    return 0
  fi

  # Check if alias already exists with correct target
  if grep -qF "alias ubs=" "$rc_file" 2>/dev/null; then
    log "Alias already exists, verifying..."
    if grep -qF "alias ubs='$script_path'" "$rc_file" 2>/dev/null || \
       grep -qF "alias ubs=\"$script_path\"" "$rc_file" 2>/dev/null; then
      log "Existing alias is correct"
      return 0
    else
      warn "Existing alias points to different location, updating..."
      # Remove old alias (note: macOS requires the .bak extension, Linux doesn't mind)
      sed -i.bak "/alias ubs=/d" "$rc_file" 2>/dev/null && rm -f "${rc_file}.bak" || {
        warn "Could not update existing alias - you may need to manually remove it"
      }
    fi
  fi

  # Add alias pointing to the installed location
  echo "" >> "$rc_file"
  echo "# Ultimate Bug Scanner alias" >> "$rc_file"
  echo "alias ubs='$script_path'" >> "$rc_file"
  success "Created 'ubs' alias pointing to: $script_path"

  log "Restart your shell or run: source $rc_file"
}

setup_claude_code_hook() {
  if [ ! -d ".claude" ]; then
    mkdir -p ".claude"
    log "Created .claude directory for Claude Code integration."
  fi
  log "Setting up Claude Code hook..."

  local hook_dir=".claude/hooks"
  local hook_file="$hook_dir/on-file-write.sh"

  mkdir -p "$hook_dir"

  cat > "$hook_file" << 'HOOK_EOF'
#!/bin/bash
# Ultimate Bug Scanner - Claude Code Hook
# Runs on every file save for UBS-supported languages (JS/TS, Python, C/C++, Rust, Go, Java, Ruby)

if [[ "$FILE_PATH" =~ \.(js|jsx|ts|tsx|mjs|cjs|py|pyw|pyi|c|cc|cpp|cxx|h|hh|hpp|hxx|rs|go|java|rb)$ ]]; then
  echo "🔬 Running bug scanner..."
  if ! command -v ubs >/dev/null 2>&1; then
    echo "⚠️  'ubs' not found in PATH; install it before using this hook." >&2
    exit 0
  fi
  ubs "${PROJECT_DIR}" --ci 2>&1 | head -50
fi
HOOK_EOF

  chmod +x "$hook_file"
  success "Claude Code hook created: $hook_file"
}

append_agent_rule_block() {
  local agent_dir="$1"
  local friendly_name="$2"
  local file="$agent_dir/rules"
  local marker="Ultimate Bug Scanner Integration"

  mkdir -p "$agent_dir"
  if [ -f "$file" ] && grep -q "$marker" "$file"; then
    log "$friendly_name instructions already present at $file"
    return 0
  fi

  cat >> "$file" <<'RULE'
# >>> Ultimate Bug Scanner Integration
# Always run the unified scanner before finalizing work:
#   1. Execute: ubs --fail-on-warning .
#   2. Review and fix any findings (critical + warning) before marking a task complete.
#   3. Mention outstanding issues in your response if they remain.
# This keeps AI coding agents honest about quality.
# <<< End Ultimate Bug Scanner Integration

RULE
  success "Added $friendly_name quality instructions at $file"
}

setup_cursor_rules() {
  append_agent_rule_block ".cursor" "Cursor"
}

setup_codex_rules() {
  append_agent_rule_block ".codex" "Codex CLI"
}

setup_gemini_rules() {
  append_agent_rule_block ".gemini" "Gemini Code Assist"
}

setup_windsurf_rules() {
  append_agent_rule_block ".windsurf" "Windsurf"
}

setup_cline_rules() {
  append_agent_rule_block ".cline" "Cline"
}

setup_opencode_rules() {
  append_agent_rule_block ".opencode" "OpenCode"
}

setup_aider_rules() {
  local aider_conf="${HOME}/.aider.conf.yml"

  log "Setting up Aider integration..."

  if [ ! -f "$aider_conf" ]; then
    cat > "$aider_conf" << 'AIDER'
# Aider configuration with UBS integration
lint-cmd: "ubs --fail-on-warning ."
auto-lint: true
AIDER
    success "Created Aider config with UBS integration: $aider_conf"
  else
    if ! grep -q "ubs" "$aider_conf" 2>/dev/null; then
      echo "" >> "$aider_conf"
      echo "# Ultimate Bug Scanner integration" >> "$aider_conf"
      echo "lint-cmd: \"ubs --fail-on-warning .\"" >> "$aider_conf"
      echo "auto-lint: true" >> "$aider_conf"
      success "Added UBS to Aider config: $aider_conf"
    else
      log "Aider already configured with UBS"
    fi
  fi
}

setup_continue_rules() {
  local continue_dir=".continue"
  mkdir -p "$continue_dir"

  log "Setting up Continue integration..."

  local config="$continue_dir/config.json"
  if [ ! -f "$config" ]; then
    cat > "$config" << 'CONTINUE'
{
  "customCommands": [
    {
      "name": "scan-bugs",
      "description": "Run Ultimate Bug Scanner on current project",
      "prompt": "Run 'ubs --fail-on-warning .' and fix any critical issues found before proceeding"
    }
  ],
  "slashCommands": [
    {
      "name": "quality",
      "description": "Check code quality with UBS",
      "run": "ubs ."
    }
  ]
}
CONTINUE
    success "Created Continue config with UBS commands: $config"
  else
    log "Continue config already exists: $config"
    log "Add UBS commands manually if needed"
  fi
}

setup_copilot_instructions() {
  local copilot_file=".github/copilot-instructions.md"

  log "Setting up GitHub Copilot instructions..."

  if [ ! -d ".github" ]; then
    mkdir -p ".github"
  fi

  if [ ! -f "$copilot_file" ]; then
    cat > "$copilot_file" << 'COPILOT'
# GitHub Copilot Instructions

## Code Quality Standards

Before suggesting code changes or completing implementations, ensure:

1. Run Ultimate Bug Scanner: `ubs --fail-on-warning .`
2. Fix any critical issues found
3. Address warnings when possible
4. Follow the bug patterns detected by UBS

## Workflow

- After generating significant code (>50 lines), recommend running: `ubs .`
- For security-sensitive code, always run scanner before commit
- Reference UBS findings in code review comments

## Integration

UBS detects 1000+ bug patterns across JavaScript/TypeScript, Python, C/C++, Rust, Go, Java, and Ruby.
COPILOT
    success "Created Copilot instructions: $copilot_file"
  else
    log "Copilot instructions already exist: $copilot_file"
  fi
}

setup_git_hook() {
  if [ ! -d ".git" ]; then
    log "Not in a git repository. Skipping..."
    return 0
  fi

  log "Setting up git pre-commit hook..."

  local hook_file=".git/hooks/pre-commit"

  # Backup existing hook if present
  if [ -f "$hook_file" ]; then
    cp "$hook_file" "${hook_file}.backup"
    warn "Existing hook backed up to ${hook_file}.backup"
  fi

  cat > "$hook_file" << 'HOOK_EOF'
#!/bin/bash
# Ultimate Bug Scanner - Pre-commit Hook
# Prevents commits with critical issues

echo "🔬 Running bug scanner..."

if ! command -v ubs >/dev/null 2>&1; then
  echo "❌ 'ubs' command not found. Install Ultimate Bug Scanner before committing." >&2
  exit 1
fi

if ! ubs . --fail-on-warning 2>&1 | tee /tmp/bug-scan.txt | tail -30; then
  echo ""
  echo "❌ Bug scanner found issues. Fix them or use: git commit --no-verify"
  exit 1
fi

echo "✓ No critical issues found"
HOOK_EOF

  chmod +x "$hook_file"
  success "Git pre-commit hook created: $hook_file"
  log "To bypass: git commit --no-verify"
}

detect_coding_agents() {
  HAS_AGENT_CLAUDE=0
  HAS_AGENT_CODEX=0
  HAS_AGENT_CURSOR=0
  HAS_AGENT_GEMINI=0
  HAS_AGENT_OPENCODE=0
  HAS_AGENT_WINDSURF=0
  HAS_AGENT_CLINE=0
  HAS_AGENT_AIDER=0
  HAS_AGENT_CONTINUE=0
  HAS_AGENT_COPILOT=0
  HAS_AGENT_TABNINE=0
  HAS_AGENT_REPLIT=0

  [[ -d "${HOME}/.claude" || -d ".claude" ]] && HAS_AGENT_CLAUDE=1
  [[ -d "${HOME}/.codex"  || -d ".codex"  ]] && HAS_AGENT_CODEX=1
  [[ -d "${HOME}/.cursor" || -d ".cursor" ]] && HAS_AGENT_CURSOR=1
  [[ -d "${HOME}/.gemini" || -d ".gemini" ]] && HAS_AGENT_GEMINI=1
  [[ -d "${HOME}/.opencode" || -d ".opencode" ]] && HAS_AGENT_OPENCODE=1
  [[ -d "${HOME}/.windsurf" || -d ".windsurf" ]] && HAS_AGENT_WINDSURF=1
  [[ -d "${HOME}/.cline" || -d ".cline" ]] && HAS_AGENT_CLINE=1

  # Aider detection (look for .aider config)
  [[ -f "${HOME}/.aider.conf.yml" || -f ".aider.conf.yml" || -f ".aider.config.yml" ]] && HAS_AGENT_AIDER=1

  # Continue detection (VS Code extension or .continue directory)
  if [ -d "$HOME/.vscode/extensions" ]; then
    ls "$HOME/.vscode/extensions"/continue.* >/dev/null 2>&1 && HAS_AGENT_CONTINUE=1
  fi
  [[ -d "${HOME}/.continue" || -d ".continue" ]] && HAS_AGENT_CONTINUE=1

  # GitHub Copilot detection
  if [ -d "$HOME/.vscode/extensions" ]; then
    ls "$HOME/.vscode/extensions"/github.copilot* >/dev/null 2>&1 && HAS_AGENT_COPILOT=1
  fi

  # Tabnine detection
  [[ -d "$HOME/.tabnine" ]] && HAS_AGENT_TABNINE=1

  # Replit Agent detection (look for .replit file)
  [[ -f ".replit" ]] && HAS_AGENT_REPLIT=1
}

add_to_agents_md() {
  local agents_file="AGENTS.md"

  if [ ! -f "$agents_file" ]; then
    log "No AGENTS.md found in current directory"
    return 0
  fi

  # Check if file is writable
  if [ ! -w "$agents_file" ]; then
    error "AGENTS.md exists but is not writable - check permissions"
    return 1
  fi

  # Check if already added (look for the specific section header)
  if grep -qF "## Code Quality: Ultimate Bug Scanner" "$agents_file" 2>/dev/null; then
    log "AGENTS.md already contains scanner documentation"
    return 0
  fi

  log "Adding scanner section to AGENTS.md..."

  # Backup original file
  if ! cp "$agents_file" "${agents_file}.backup" 2>/dev/null; then
    warn "Could not create backup of AGENTS.md"
  fi

  cat >> "$agents_file" << 'AGENTS_EOF'

## Code Quality: Ultimate Bug Scanner

### When to Use

Run the bug scanner **before committing** any JavaScript/TypeScript, Python, C/C++, Rust, Go, Java, or Ruby code changes:

```bash
ubs .
```

### Requirements

- Run automatically after implementing features
- Run before marking work as complete
- Fix all CRITICAL issues before committing
- Consider fixing WARNING issues

### Integration

The scanner may be configured to run automatically via:
- Claude Code hooks (runs on file save)
- Git pre-commit hooks (runs before commit)

If hooks are configured, the scanner runs automatically and you don't need to invoke it manually.

### More Information

See the [Ultimate Bug Scanner repository](https://github.com/Dicklesworthstone/ultimate_bug_scanner) for complete documentation.
AGENTS_EOF

  success "Added section to AGENTS.md"
}

maybe_setup_hook() {
  local label="$1"
  local detected_flag="$2"
  local fn_name="$3"

  if [ "$detected_flag" != "-1" ] && [ "$detected_flag" -eq 0 ]; then
    log "Skipping ${label} (agent not detected)"
    return 0
  fi

  if [ "$EASY_MODE" -eq 1 ]; then
    "$fn_name"
  else
    if ask "Set up ${label}?"; then
      "$fn_name"
    fi
  fi
}

main() {
  # Concurrent execution lock to prevent race conditions
  if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    error "Another installation is already in progress"
    error "If this is incorrect, remove: $LOCK_FILE"
    exit 1
  fi
  # Mark that we own the lock (so cleanup will remove it)
  LOCK_OWNED=1

  # Save original arguments for potential re-exec during update
  local ORIGINAL_ARGS=("$@")

  # Load configuration file (before argument parsing so CLI args can override)
  read_config_file

  print_header

  # Check for updates (unless skipped or updating)
  if [ "$SKIP_VERSION_CHECK" -eq 0 ] && [[ ! " ${ORIGINAL_ARGS[*]} " =~ " --update " ]]; then
    check_for_updates
    echo ""
  fi

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --easy-mode)
        EASY_MODE=1
        NON_INTERACTIVE=1
        shift
        ;;
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      --skip-ast-grep)
        SKIP_AST_GREP=1
        shift
        ;;
      --skip-ripgrep)
        SKIP_RIPGREP=1
        shift
        ;;
      --skip-jq)
        SKIP_JQ=1
        shift
        ;;
      --skip-hooks)
        SKIP_HOOKS=1
        shift
        ;;
      --skip-version-check)
        SKIP_VERSION_CHECK=1
        shift
        ;;
      --skip-verification)
        RUN_VERIFICATION=0
        shift
        ;;
      --update)
        FORCE_REINSTALL=1
        shift
        ;;
      --install-dir)
        INSTALL_DIR="$2"
        shift 2
        ;;
      --setup-git-hook)
        setup_git_hook
        exit 0
        ;;
      --setup-claude-hook)
        setup_claude_code_hook
        exit 0
        ;;
      --generate-config)
        generate_config
        exit 0
        ;;
      --diagnose)
        diagnostic_check
        exit 0
        ;;
      --uninstall)
        uninstall_ubs
        exit 0
        ;;
      --help)
        echo "Usage: install.sh [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --easy-mode             Accept all prompts, install deps, and wire integrations"
        echo "  --non-interactive       Skip all prompts (use defaults)"
        echo "  --update                Force reinstall to latest version"
        echo "  --skip-ast-grep         Skip ast-grep installation"
        echo "  --skip-ripgrep          Skip ripgrep installation"
        echo "  --skip-jq               Skip jq installation"
        echo "  --skip-hooks            Skip hook setup"
        echo "  --skip-version-check    Don't check for updates"
        echo "  --skip-verification     Skip post-install verification"
        echo "  --install-dir DIR       Custom installation directory"
        echo "  --setup-git-hook        Only set up git hook (no install)"
        echo "  --setup-claude-hook     Only set up Claude Code hook (no install)"
        echo "  --generate-config       Create configuration file at ~/.config/ubs/install.conf"
        echo "  --diagnose              Run diagnostic check and show system information"
        echo "  --uninstall             Remove UBS and all integrations"
        echo "  --help                  Show this help"
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        exit 1
        ;;
    esac
  done

  log "Detected platform: $(detect_platform)"
  log "Detected shell: $(detect_shell)"
  if [ "$EASY_MODE" -eq 1 ]; then
    log "Easy mode enabled: auto-confirming prompts and wiring integrations."
  fi
  echo ""

  # Check for ast-grep
  if ! check_ast_grep && [ "$SKIP_AST_GREP" -eq 0 ]; then
    warn "ast-grep not found (recommended for best results)"
    if ask "Install ast-grep now?"; then
      install_ast_grep || warn "Continuing without ast-grep (regex mode only)"
    fi
    echo ""
  else
    success "ast-grep is installed"
    echo ""
  fi

  # Check for ripgrep
  if ! check_ripgrep && [ "$SKIP_RIPGREP" -eq 0 ]; then
    warn "ripgrep not found (required for optimal performance)"
    if ask "Install ripgrep now?"; then
      install_ripgrep || warn "Continuing without ripgrep (may use slower grep fallback)"
    fi
    echo ""
  else
    success "ripgrep is installed"
    echo ""
  fi

  # Check for jq
  if ! check_jq && [ "$SKIP_JQ" -eq 0 ]; then
    warn "jq not found (required for JSON/SARIF merging)"
    if ask "Install jq now?"; then
      install_jq || warn "Continuing without jq (merged outputs disabled)"
    fi
    echo ""
  else
    success "jq is installed"
    echo ""
  fi

  # Install the scanner
  if ! install_scanner; then
    error "Installation failed"
    exit 1
  fi
  echo ""

  # Add to PATH
  add_to_path
  echo ""

  # Create alias
  create_alias
  echo ""

  detect_coding_agents
  log "Detected coding agents:"
  log "  Core: claude=${HAS_AGENT_CLAUDE} codex=${HAS_AGENT_CODEX} cursor=${HAS_AGENT_CURSOR}"
  log "  Extended: gemini=${HAS_AGENT_GEMINI} windsurf=${HAS_AGENT_WINDSURF} cline=${HAS_AGENT_CLINE} opencode=${HAS_AGENT_OPENCODE}"
  log "  Additional: aider=${HAS_AGENT_AIDER} continue=${HAS_AGENT_CONTINUE} copilot=${HAS_AGENT_COPILOT} tabnine=${HAS_AGENT_TABNINE} replit=${HAS_AGENT_REPLIT}"

  # Setup hooks / guardrails
  if [ "$SKIP_HOOKS" -eq 0 ]; then
    maybe_setup_hook "Git pre-commit hook" -1 setup_git_hook
    maybe_setup_hook "Claude Code on-save hook (.claude/hooks/on-file-write.sh)" "$HAS_AGENT_CLAUDE" setup_claude_code_hook
    maybe_setup_hook "Cursor guardrails (.cursor/rules)" "$HAS_AGENT_CURSOR" setup_cursor_rules
    maybe_setup_hook "Codex CLI guardrails (.codex/rules)" "$HAS_AGENT_CODEX" setup_codex_rules
    maybe_setup_hook "Gemini Code Assist guardrails (.gemini/rules)" "$HAS_AGENT_GEMINI" setup_gemini_rules
    maybe_setup_hook "Windsurf guardrails (.windsurf/rules)" "$HAS_AGENT_WINDSURF" setup_windsurf_rules
    maybe_setup_hook "Cline guardrails (.cline/rules)" "$HAS_AGENT_CLINE" setup_cline_rules
    maybe_setup_hook "OpenCode MCP guardrails (.opencode/rules)" "$HAS_AGENT_OPENCODE" setup_opencode_rules
    maybe_setup_hook "Aider integration (.aider.conf.yml)" "$HAS_AGENT_AIDER" setup_aider_rules
    maybe_setup_hook "Continue integration (.continue/config.json)" "$HAS_AGENT_CONTINUE" setup_continue_rules
    maybe_setup_hook "GitHub Copilot instructions (.github/copilot-instructions.md)" "$HAS_AGENT_COPILOT" setup_copilot_instructions
    echo ""
  fi

  # Add to AGENTS.md
  if [ -f "AGENTS.md" ]; then
    if ask "Add scanner documentation to AGENTS.md?"; then
      add_to_agents_md
    fi
    echo ""
  fi

  # Run post-install verification
  verify_installation

  # Final instructions
  echo ""
  echo -e "${BOLD}${GREEN}"
  cat << 'SUCCESS'
    ╔══════════════════════════════════════════════════════════════════╗
    ║                                                                  ║
    ║     ✨  INSTALLATION COMPLETE! ✨                                ║
    ║                                                                  ║
    ║         Your code quality just leveled up! 🚀                   ║
    ║                                                                  ║
    ╚══════════════════════════════════════════════════════════════════╝
SUCCESS
  echo -e "${RESET}"
  echo ""

  # Check if ubs command is immediately available
  local cmd_available=0
  if command -v ubs >/dev/null 2>&1; then
    cmd_available=1
  fi

  if [ "$cmd_available" -eq 1 ]; then
    echo -e "${BOLD}${GREEN}┌─ Ready to Use! ✓${RESET}"
    echo -e "${GREEN}│${RESET}"
    echo -e "${GREEN}└──${RESET} The ${BOLD}ubs${RESET} command is available now!"
    echo ""
    echo -e "${BOLD}${BLUE}┌─ Quick Start${RESET}"
    echo -e "${BLUE}│${RESET}"
    echo -e "${BLUE}├──${RESET} ${BOLD}Run scanner:${RESET}    ${GREEN}ubs .${RESET}"
    echo -e "${BLUE}├──${RESET} ${BOLD}Get help:${RESET}       ${GREEN}ubs --help${RESET}"
    echo -e "${BLUE}└──${RESET} ${BOLD}Verbose mode:${RESET}   ${GREEN}ubs -v .${RESET}"
  else
    echo -e "${BOLD}${YELLOW}┌─ Almost Done! (Reload Required)${RESET}"
    echo -e "${YELLOW}│${RESET}"
    echo -e "${YELLOW}└──${RESET} Run: ${BOLD}${GREEN}source $(get_rc_file)${RESET}"
    echo ""
    echo -e "${BOLD}${BLUE}┌─ Then Try${RESET}"
    echo -e "${BLUE}│${RESET}"
    echo -e "${BLUE}├──${RESET} ${BOLD}Run scanner:${RESET}    ${GREEN}ubs .${RESET}"
    echo -e "${BLUE}├──${RESET} ${BOLD}Get help:${RESET}       ${GREEN}ubs --help${RESET}"
    echo -e "${BLUE}└──${RESET} ${BOLD}Verbose mode:${RESET}   ${GREEN}ubs -v .${RESET}"
  fi

  echo ""
  echo -e "${BOLD}${BLUE}📚 Documentation:${RESET} ${BLUE}https://github.com/Dicklesworthstone/ultimate_bug_scanner${RESET}"
  echo ""
  echo -e "${GREEN}${BOLD}Happy bug hunting! 🐛🔫${RESET}"
  echo ""
}

main "$@"
