#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# SWIFT ULTIMATE BUG SCANNER v1.3 (Bash) - Industrial-Grade Code Analysis
# ═══════════════════════════════════════════════════════════════════════════
# Comprehensive static analysis for modern Swift (6.2+) for iOS & macOS using:
#   • ast-grep (rule packs; language: swift)
#   • precise Info.plist ATS parsing via plistlib (when Python 3 available)
#   • ripgrep/grep heuristics for fast code smells
#   • optional extra analyzers if available:
#       - SwiftLint (linting/best practices)
#       - SwiftFormat (formatting/style)
#       - Periphery (dead code)
#       - xcodebuild analyze (Clang static analyzer)
#
# Focus:
#   • Optionals & force operations  • async/await & Task lifecycle
#   • URLSession pitfalls           • memory cycles & capture lists
#   • security/crypto               • Info.plist ATS & entitlements
#   • resource lifecycle (Timer, Notification tokens, FileHandle)
#   • Combine/SwiftUI leaks         • performance & main-thread issues
#
# Supports:
#   --format text|json|sarif (ast-grep passthrough for json/sarif)
#   --rules DIR   (merge user ast-grep rules)
#   --fail-on-warning, --skip, --jobs, --include-ext, --exclude, --ci, --no-color, --force-color
#   --summary-json FILE  (machine-readable run summary with rule histogram)
#   --max-detailed N     (cap detailed code samples)
#   --list-categories    (print category index and exit)
#   --list-rules         (print embedded ast-grep rule ids and exit)
#   --timeout-seconds N  (global external tool timeout budget)
#   --baseline FILE      (compare current totals to prior summary JSON)
#   --max-file-size SIZE (ripgrep limit, e.g., 25M)
#   --sdk ios|macos|tvos|watchos (for xcodebuild analyze heuristics)
#   --only=CSV           (only run the given category numbers)
#
# CI-friendly timestamps, robust find, safe pipelines, auto parallel jobs.
# Heavily leverages ast-grep for Swift via rule packs; complements with rg.
# Adds portable timeout resolution (timeout/gtimeout) and UTF‑8-safe output.
# ═══════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail
shopt -s lastpipe
shopt -s extglob
shopt -s compat31 || true

VERSION="1.3.0"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

on_err() {
  local ec=$?; local cmd=${BASH_COMMAND}; local line=${BASH_LINENO[0]}; local src=${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}
  echo -e "\n${RED}${BOLD}Unexpected error (exit $ec)${RESET} ${DIM}at ${src}:${line}${RESET}\n${DIM}Last command:${RESET} ${WHITE}$cmd${RESET}" >&2 || true
  exit "$ec"
}
trap on_err ERR

# ANSI color plumbing (initialized later after CLI/redirect decisions)
USE_COLOR=0; FORCE_COLOR=0; NO_COLOR_FLAG=0
RED=''; GREEN=''; YELLOW=''; BLUE=''; ORANGE=''; MAGENTA=''; CYAN=''; WHITE=''; GRAY=''
BOLD=''; DIM=''; RESET=''
init_colors() {
  # Honor NO_COLOR, --no-color, stdout TTY, and file output
  if [[ -n "${NO_COLOR:-}" ]]; then USE_COLOR=0; fi
  if [[ "$NO_COLOR_FLAG" -eq 1 ]]; then USE_COLOR=0; fi
  if [[ ! -t 1 ]]; then USE_COLOR=0; fi
  if [[ "$FORCE_COLOR" -eq 1 ]]; then USE_COLOR=1; fi
  if [[ -n "${OUTPUT_FILE:-}" && "$FORCE_COLOR" -eq 0 && "$NO_COLOR_FLAG" -eq 0 ]]; then USE_COLOR=0; fi
  if [[ "$USE_COLOR" -eq 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
    ORANGE='\033[0;33m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;90m'
    BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
  else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; ORANGE=''; MAGENTA=''; CYAN=''; WHITE=''; GRAY=''; BOLD=''; DIM=''; RESET=''
  fi
}

SAFE_LOCALE="C"
if locale -a 2>/dev/null | grep -qiE '^(C\.UTF-8|en_US\.UTF-8)$'; then SAFE_LOCALE="C.UTF-8"; fi
export LC_CTYPE="${SAFE_LOCALE}"
export LC_MESSAGES="${SAFE_LOCALE}"
export LANG="${SAFE_LOCALE}"

CHECK="✓"; CROSS="✗"; WARN="⚠"; INFO="ℹ"; ARROW="→"; BULLET="•"; MAGNIFY="🔍"; BUG="🐛"; FIRE="🔥"; SPARKLE="✨"; SHIELD="🛡"; ROCKET="🚀"

# category context & counters
CURRENT_CATEGORY_ID=0

# ────────────────────────────────────────────────────────────────────────────
# CLI Parsing & Configuration
# ────────────────────────────────────────────────────────────────────────────
VERBOSE=0
PROJECT_DIR="."
OUTPUT_FILE=""
FORMAT="text"          # text|json|sarif
CI_MODE=0
FAIL_ON_WARNING=0
BASELINE=""
LIST_CATEGORIES=0
MAX_FILE_SIZE="${MAX_FILE_SIZE:-25M}"
INCLUDE_EXT="swift,mm,m,metal,plist,xib,storyboard,xcconfig"
QUIET=0
EXTRA_EXCLUDES=""
SKIP_CATEGORIES=""
ONLY_CATEGORIES=""
DETAIL_LIMIT=3
MAX_DETAILED=250
JOBS="${JOBS:-0}"
USER_RULE_DIR=""
SUMMARY_JSON=""
TIMEOUT_CMD=""
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-0}"
AST_PASSTHROUGH=0
SDK_KIND="${SDK_KIND:-ios}"
LIST_RULES=0

# Category filter hook
CATEGORY_WHITELIST=""
case "${SUBS_CATEGORY_FILTER:-}" in
  resource-lifecycle)
    CATEGORY_WHITELIST="16,19"
    ;;
esac

# Async error coverage metadata (Swift)
ASYNC_RULE_IDS=(swift.task.floating swift.continuation.no-resume swift.task.detached-no-handle)
declare -A ASYNC_ERROR_SUMMARY=(
  [swift.task.floating]='Task { ... } result unused'
  [swift.continuation.no-resume]='withChecked/UnsafeContinuation without resume'
  [swift.task.detached-no-handle]='Task.detached without handle or cancel'
)
declare -A ASYNC_ERROR_REMEDIATION=(
  [swift.task.floating]='Store handle and cancel on deinit/shutdown'
  [swift.continuation.no-resume]='Ensure every path calls continuation.resume(...) exactly once'
  [swift.task.detached-no-handle]='Avoid unstructured tasks; keep a reference or use structured concurrency'
)
declare -A ASYNC_ERROR_SEVERITY=(
  [swift.task.floating]='warning'
  [swift.continuation.no-resume]='critical'
  [swift.task.detached-no-handle]='warning'
)

# Resource lifecycle correlation spec (Swift)
RESOURCE_LIFECYCLE_IDS=(timer urlsession_task notification_token file_handle combine_sink dispatch_source)
declare -A RESOURCE_LIFECYCLE_SEVERITY=(
  [timer]="warning"
  [urlsession_task]="warning"
  [notification_token]="warning"
  [file_handle]="critical"
  [combine_sink]="warning"
  [dispatch_source]="warning"
)
declare -A RESOURCE_LIFECYCLE_ACQUIRE=(
  [timer]='Timer\.scheduledTimer|Timer\.publish\('
  [urlsession_task]='URLSession\.[A-Za-z_]+\s*\.dataTask|URLSession\.[A-Za-z_]+\s*\.uploadTask|URLSession\.[A-Za-z_]+\s*\.downloadTask'
  [notification_token]='NotificationCenter\.default\.addObserver\([^)]*using:\s*\{'
  [file_handle]='FileHandle\((forReading|forWriting|forUpdating)AtPath|forReadingFrom|forWritingTo|forUpdatingAtPath)'
  [combine_sink]='\.sink\('
  [dispatch_source]='DispatchSource\.(makeTimerSource|makeFileSystemObjectSource|makeReadSource|makeWriteSource)'
)
declare -A RESOURCE_LIFECYCLE_RELEASE=(
  [timer]='\.invalidate\('
  [urlsession_task]='\.resume\(|\.cancel\('
  [notification_token]='NotificationCenter\.default\.removeObserver\('
  [file_handle]='\.close\('
  [combine_sink]='\.store\(in:\s*&'
  [dispatch_source]='\.cancel\('
)
declare -A RESOURCE_LIFECYCLE_SUMMARY=(
  [timer]='Timer scheduled but never invalidated'
  [urlsession_task]='URLSession task created but not resumed/cancelled'
  [notification_token]='NotificationCenter block-based observer not removed'
  [file_handle]='FileHandle opened without close()'
  [combine_sink]='Combine sink not stored, may be dropped immediately'
  [dispatch_source]='DispatchSource created but not cancelled'
)
declare -A RESOURCE_LIFECYCLE_REMEDIATION=(
  [timer]='Keep a reference and call timer.invalidate() (e.g., deinit)'
  [urlsession_task]='Call task.resume(); cancel on teardown if needed'
  [notification_token]='Keep the token and call removeObserver(token)'
  [file_handle]='Use try-with-resource semantics; call close() in defer'
  [combine_sink]='Store AnyCancellable in a Set<AnyCancellable>'
  [dispatch_source]='Call source.setEventHandler{}, resume(), and cancel()'
)

print_usage() {
  cat >&2 <<USAGE
Usage: $(basename "$0") [options] [PROJECT_DIR] [OUTPUT_FILE]

Options:
  --list-categories       Print numbered categories and exit
  --list-rules            Print embedded ast-grep rule IDs and exit
  --timeout-seconds=N     Global per-tool timeout budget
  --baseline=FILE         Compare against a previous run's summary JSON
  --max-file-size=SIZE    Limit ripgrep file size (default: $MAX_FILE_SIZE)
  --force-color           Force ANSI even if not TTY
  -v, --verbose           More code samples per finding (DETAIL=10)
  -q, --quiet             Reduce non-essential output
  --format=FMT            Output: text|json|sarif (default: text)
  --ci                    CI mode (UTC timestamps)
  --no-color              Disable ANSI color
  --include-ext=CSV       File extensions (default: $INCLUDE_EXT)
  --exclude=GLOB[,..]     Additional glob(s)/dir(s) to exclude
  --jobs=N                Parallel jobs for ripgrep (default: auto)
  --skip=CSV              Skip categories by number (e.g., --skip=2,7,11)
  --only=CSV              Only run these categories (e.g., --only=1,2,4)
  --fail-on-warning       Exit non-zero on warnings or critical
  --rules=DIR             Additional ast-grep rules dir (merged)
  --summary-json=FILE     Write machine-readable summary JSON
  --max-detailed=N        Cap number of detailed samples (default: $MAX_DETAILED)
  --sdk=KIND              ios|macos|tvos|watchos (default: $SDK_KIND)
Env:
  JOBS, NO_COLOR, CI, TIMEOUT_SECONDS, MAX_FILE_SIZE, SUBS_CATEGORY_FILTER
Args:
  PROJECT_DIR             Directory to scan (default: ".")
  OUTPUT_FILE             File to save the report (optional)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; DETAIL_LIMIT=10; shift;;
    -q|--quiet)   VERBOSE=0; DETAIL_LIMIT=1; QUIET=1; shift;;
    --format=*)   FORMAT="${1#*=}"; shift;;
    --ci)         CI_MODE=1; shift;;
    --no-color)   NO_COLOR_FLAG=1; shift;;
    --force-color) FORCE_COLOR=1; shift;;
    --version)    echo "ubs-swift ${VERSION}"; exit 0;;
    --timeout-seconds=*) TIMEOUT_SECONDS="${1#*=}"; shift;;
    --baseline=*) BASELINE="${1#*=}"; shift;;
    --list-categories) LIST_CATEGORIES=1; shift;;
    --list-rules) LIST_RULES=1; shift;;
    --max-file-size=*) MAX_FILE_SIZE="${1#*=}"; shift;;
    --include-ext=*) INCLUDE_EXT="${1#*=}"; shift;;
    --exclude=*)  EXTRA_EXCLUDES="${1#*=}"; shift;;
    --jobs=*)     JOBS="${1#*=}"; shift;;
    --skip=*)     SKIP_CATEGORIES="${1#*=}"; shift;;
    --only=*)     ONLY_CATEGORIES="${1#*=}"; shift;;
    --fail-on-warning) FAIL_ON_WARNING=1; shift;;
    --rules=*)    USER_RULE_DIR="${1#*=}"; shift;;
    --summary-json=*) SUMMARY_JSON="${1#*=}"; shift;;
    --max-detailed=*) MAX_DETAILED="${1#*=}"; shift;;
    --sdk=*) SDK_KIND="${1#*=}"; shift;;
    -h|--help)    print_usage; exit 0;;
    *)
      if [[ -z "$PROJECT_DIR" || "$PROJECT_DIR" == "." ]] && ! [[ "$1" =~ ^- ]]; then
        PROJECT_DIR="$1"; shift
      elif [[ -z "$OUTPUT_FILE" ]] && ! [[ "$1" =~ ^- ]]; then
        OUTPUT_FILE="$1"; shift
      else
        echo "Unexpected argument: $1" >&2; exit 2
      fi
      ;;
  esac
done

# Validate format early
case "$FORMAT" in
  text|json|sarif) ;;
  *) echo "Unsupported --format=$FORMAT (expected: text|json|sarif)" >&2; exit 2 ;;
esac

if [[ "$LIST_CATEGORIES" -eq 1 ]]; then
  cat <<'CAT'
1 Optionals/Force Ops   2 Concurrency/Task     3 Closures/Captures  4 URLSession
5 Error Handling        6 Security              7 Crypto/Hashing     8 Files & I/O
9 Threading/Main        10 Performance          11 Debug/Prod        12 Regex
13 SwiftUI/Combine      14 Memory/Retain        15 Code Quality      16 Resource Lifecycle
17 Info.plist/ATS       18 Deprecated APIs      19 Build/Signing     20 Packaging/SPM
21 UI/UX Safety         22 Tests/Hygiene        23 Localize/Intl
CAT
  exit 0
fi

# CI auto-detect + colors
if [[ -n "${CI:-}" ]]; then CI_MODE=1; fi

# Redirect if requested, then compute colors with final state
if [[ -n "${OUTPUT_FILE}" ]]; then exec > >(tee "${OUTPUT_FILE}") 2>&1; fi
init_colors

safe_date() {
  if [[ "$CI_MODE" -eq 1 ]]; then command date -u '+%Y-%m-%dT%H:%M:%SZ' || command date '+%Y-%m-%dT%H:%M:%SZ'; else command date '+%Y-%m-%d %H:%M:%S'; fi
}
DATE_CMD="safe_date"

# ────────────────────────────────────────────────────────────────────────────
# Global Counters
# ────────────────────────────────────────────────────────────────────────────
CRITICAL_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0
TOTAL_FILES=0

# ────────────────────────────────────────────────────────────────────────────
# Global State
# ────────────────────────────────────────────────────────────────────────────
for __i in $(seq 1 23); do
  eval "CAT${__i}=0"
  eval "CAT${__i}_critical=0"
  eval "CAT${__i}_warning=0"
  eval "CAT${__i}_info=0"
done

set_category() { CURRENT_CATEGORY_ID="$1"; }
inc_category_total() {
  local c="${1:-0}"; local id="$CURRENT_CATEGORY_ID"; local vname="CAT${id}"
  eval "$vname=\$(( \${$vname:-0} + c ))"
}
HAS_AST_GREP=0
AST_GREP_CMD=()
AST_RULE_DIR=""
HAS_RIPGREP=0
RG_MAX_SIZE_FLAGS=()

# Excludes / Includes
IFS=',' read -r -a _EXT_ARR <<<"$INCLUDE_EXT"
INCLUDE_GLOBS=()
for e in "${_EXT_ARR[@]}"; do INCLUDE_GLOBS+=( "--include=*.$(echo "$e" | xargs)" ); done

EXCLUDE_DIRS=(.git .hg .svn .bzr .build build DerivedData .swiftpm .sourcery .periphery .mint .cache .xcarchive .xcresult .xcassets Pods Carthage vendor .idea .vscode .history .swiftformat .swiftlint)
if [[ -n "$EXTRA_EXCLUDES" ]]; then IFS=',' read -r -a _X <<<"$EXTRA_EXCLUDES"; EXCLUDE_DIRS+=("${_X[@]}"); fi
EXCLUDE_FLAGS=()
for d in "${EXCLUDE_DIRS[@]}"; do EXCLUDE_FLAGS+=( "--exclude-dir=$d" ); done

if command -v rg >/dev/null 2>&1; then
  HAS_RIPGREP=1
  if [[ "${JOBS}" -eq 0 ]]; then JOBS="$( (command -v nproc >/dev/null && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 0 )"; fi
  if [[ "${JOBS}" -le 0 ]]; then JOBS=1; fi
  RG_JOBS=(); if [[ "${JOBS}" -gt 0 ]]; then RG_JOBS=(-j "$JOBS"); fi
  RG_BASE=(--no-config --no-messages --line-number --with-filename --hidden --pcre2 "${RG_JOBS[@]}")
  RG_EXCLUDES=()
  for d in "${EXCLUDE_DIRS[@]}"; do RG_EXCLUDES+=( -g "!$d/**" ); done
  RG_INCLUDES=()
  for e in "${_EXT_ARR[@]}"; do RG_INCLUDES+=( -g "*.$(echo "$e" | xargs)" ); done
  RG_MAX_SIZE_FLAGS=(--max-filesize "$MAX_FILE_SIZE")
  GREP_RN=(env LC_ALL=C rg "${RG_BASE[@]}" "${RG_EXCLUDES[@]}" "${RG_INCLUDES[@]}" "${RG_MAX_SIZE_FLAGS[@]}")
  GREP_RNI=(env LC_ALL=C rg -i "${RG_BASE[@]}" "${RG_EXCLUDES[@]}" "${RG_INCLUDES[@]}" "${RG_MAX_SIZE_FLAGS[@]}")
  GREP_RNW=(env LC_ALL=C rg -w "${RG_BASE[@]}" "${RG_EXCLUDES[@]}" "${RG_INCLUDES[@]}" "${RG_MAX_SIZE_FLAGS[@]}")
else
  GREP_R_OPTS=(-R --binary-files=without-match "${EXCLUDE_FLAGS[@]}" "${INCLUDE_GLOBS[@]}")
  GREP_RN=(env LC_ALL=C grep "${GREP_R_OPTS[@]}" -n -E)
  GREP_RNI=(env LC_ALL=C grep "${GREP_R_OPTS[@]}" -n -i -E)
  GREP_RNW=(env LC_ALL=C grep "${GREP_R_OPTS[@]}" -n -w -E)
fi

count_lines() { awk 'END{print (NR+0)}'; }
num_clamp() { local v=${1:-0}; printf '%s' "$v" | awk 'END{print ($0+0)}'; }

resolve_timeout() {
  if command -v timeout >/dev/null 2>&1; then TIMEOUT_CMD="timeout"; return 0; fi
  if command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD="gtimeout"; return 0; fi
  TIMEOUT_CMD=""
}
with_timeout() {
  if [[ -n "$TIMEOUT_CMD" && "${TIMEOUT_SECONDS:-0}" -gt 0 ]]; then "$TIMEOUT_CMD" "$TIMEOUT_SECONDS" "$@"; else "$@"; fi
}

maybe_clear() { if [[ -t 1 && "$CI_MODE" -eq 0 ]]; then clear || true; fi; }
say() { [[ "$QUIET" -eq 1 ]] && return 0; echo -e "$*"; }

print_header() {
  say "\n${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  say "${WHITE}${BOLD}$1${RESET}"
  say "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}
print_category() { say "\n${MAGENTA}${BOLD}▓▓▓ $1${RESET}\n${DIM}$2${RESET}"; }
print_subheader() { say "\n${YELLOW}${BOLD}$BULLET $1${RESET}"; }

run_swift_type_narrowing_checks() {
  if [[ "${UBS_SKIP_TYPE_NARROWING:-0}" -eq 1 ]]; then
    print_finding "info" 0 "Swift type narrowing checks skipped" "Set UBS_SKIP_TYPE_NARROWING=0 or remove --skip-type-narrowing to re-enable"
    return
  fi
  local helper="$SCRIPT_DIR/helpers/type_narrowing_swift.py"
  if [[ ! -f "$helper" ]]; then
    print_finding "info" 0 "Swift type narrowing helper missing" "$helper not found"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    print_finding "info" 0 "python3 unavailable for Swift helper" "Install python3 to enable Swift guard analysis"
    return
  fi
  local output status
  output="$(python3 "$helper" "$PROJECT_DIR" 2>&1)"
  status=$?
  if [[ $status -ne 0 ]]; then
    print_finding "info" 0 "Swift type narrowing helper failed" "$output"
    return
  fi
  if [[ -z "$output" ]]; then
    print_finding "good" "Swift guard clauses appear to exit safely"
    return
  fi
  local count=0
  local previews=()
  while IFS=$'\t' read -r location message; do
    [[ -z "$location" ]] && continue
    count=$((count + 1))
    if [[ ${#previews[@]} -lt 3 ]]; then
      previews+=("$location → $message")
    fi
  done <<< "$output"
  local desc="Examples: ${previews[*]}"
  if [[ $count -gt ${#previews[@]} ]]; then
    desc+=" (and $((count - ${#previews[@]})) more)"
  fi
  print_finding "warning" "$count" "Swift guard let else-block may continue" "$desc"
}

_bump_counts() {
  local sev="$1" cnt="$2"
  case "$sev" in
    critical) CRITICAL_COUNT=$((CRITICAL_COUNT + cnt)); eval "CAT${CURRENT_CATEGORY_ID}_critical=\$(( \${CAT${CURRENT_CATEGORY_ID}_critical:-0} + cnt ))";;
    warning)  WARNING_COUNT=$((WARNING_COUNT + cnt));  eval "CAT${CURRENT_CATEGORY_ID}_warning=\$(( \${CAT${CURRENT_CATEGORY_ID}_warning:-0} + cnt ))";;
    info)     INFO_COUNT=$((INFO_COUNT + cnt));         eval "CAT${CURRENT_CATEGORY_ID}_info=\$(( \${CAT${CURRENT_CATEGORY_ID}_info:-0} + cnt ))";;
  esac
  inc_category_total "$cnt"
}

print_finding() {
  local severity=$1
  case $severity in
    good)
      local title=$2
      say "  ${GREEN}${CHECK} OK${RESET} ${DIM}$title${RESET}"
      ;;
    *)
      local raw_count=${2:-0}; local title=$3; local description="${4:-}"
      local count; count=$(printf '%s\n' "$raw_count" | awk 'END{print $0+0}')
      _bump_counts "$severity" "$count"
      case $severity in
        critical)
          say "  ${RED}${BOLD}${FIRE} CRITICAL${RESET} ${WHITE}($count found)${RESET}"
          say "    ${RED}${BOLD}$title${RESET}"
          [ -n "$description" ] && say "    ${DIM}$description${RESET}" || true
          ;;
        warning)
          say "  ${YELLOW}${WARN} Warning${RESET} ${WHITE}($count found)${RESET}"
          say "    ${YELLOW}$title${RESET}"
          [ -n "$description" ] && say "    ${DIM}$description${RESET}" || true
          ;;
        info)
          say "  ${BLUE}${INFO} Info${RESET} ${WHITE}($count found)${RESET}"
          say "    ${BLUE}$title${RESET}"
          [ -n "$description" ] && say "    ${DIM}$description${RESET}" || true
          ;;
      esac
      ;;
  esac
}
print_code_sample(){ local file=$1; local line=$2; local code=$3; say "${GRAY}      $file:$line${RESET}"; say "${WHITE}      $code${RESET}"; }
show_detailed_finding(){ local pattern=$1; local limit=${2:-$DETAIL_LIMIT}; local printed=0; while IFS=: read -r file line code; do print_code_sample "$file" "$line" "$code"; printed=$((printed+1)); [[ $printed -ge $limit || $printed -ge $MAX_DETAILED ]] && break; done < <("${GREP_RN[@]}" -e "$pattern" "$PROJECT_DIR" 2>/dev/null | head -n "$limit" || true) || true; }

begin_scan_section(){ set +e; trap - ERR; set +o pipefail; }
end_scan_section(){ trap on_err ERR; set -e; set -o pipefail; }

# ast-grep detection
check_ast_grep() {
  if command -v ast-grep >/dev/null 2>&1; then AST_GREP_CMD=(ast-grep); HAS_AST_GREP=1; return 0; fi
  if command -v sg       >/dev/null 2>&1; then AST_GREP_CMD=(sg);       HAS_AST_GREP=1; return 0; fi
  if command -v npx      >/dev/null 2>&1; then AST_GREP_CMD=(npx -y @ast-grep/cli); HAS_AST_GREP=1; return 0; fi
  say "${YELLOW}${WARN} ast-grep not found. Advanced AST checks will be skipped.${RESET}"
  say "${DIM}Tip: npm i -g @ast-grep/cli  or  cargo install ast-grep${RESET}"
  HAS_AST_GREP=0; return 1
}

# ────────────────────────────────────────────────────────────────────────────
# AST helpers and rule pack
# ────────────────────────────────────────────────────────────────────────────
show_ast_samples_from_json() {
  local blob=$1; [[ -n "$blob" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then return 0; fi
  jq -cr '.samples[]?' <<<"$blob" | while IFS= read -r sample; do
    local file line code
    file=$(printf '%s' "$sample" | jq -r '.file')
    line=$(printf '%s' "$sample" | jq -r '.line')
    code=$(printf '%s' "$sample" | jq -r '.code')
    print_code_sample "$file" "$line" "$code"
  done
}

write_ast_rules() {
  [[ "$HAS_AST_GREP" -eq 1 ]] || return 0
  AST_RULE_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t swift_ag_rules.XXXXXX)"
  trap '[[ -n "${AST_RULE_DIR:-}" ]] && rm -rf "$AST_RULE_DIR" || true' EXIT
  if [[ -n "$USER_RULE_DIR" && -d "$USER_RULE_DIR" ]]; then
    cp -R "$USER_RULE_DIR"/. "$AST_RULE_DIR"/ 2>/dev/null || true
  fi
  # Mergeable rule listing support
  if [[ "$LIST_RULES" -eq 1 ]]; then
    say "${WHITE}${BOLD}Embedded ast-grep rules:${RESET}"
    shopt -s nullglob
    for f in "$AST_RULE_DIR"/*.yml; do
      [[ -f "$f" ]] || continue
      awk 'BEGIN{ id=""; sev="info"; msg="" } /^id:/{id=$2} /^severity:/{sev=$2} /^message:/{sub(/^message:[ ]*/,""); msg=$0; print "  - " id " [" sev "] " msg }' "$f"
    done
    shopt -u nullglob
    exit 0
  fi
  # All rules below target Swift (tree-sitter-swift). Where needed, regex is used on leaf text.

  # ── Core Swift rules ──────────────────────────────────────────────────────
  cat >"$AST_RULE_DIR/force-unwrap.yml" <<'YAML'
id: swift.force-unwrap
language: swift
rule: { pattern: $EXPR! }
severity: warning
message: "Force unwrap; prefer optional binding (if let/guard let)."
YAML

  cat >"$AST_RULE_DIR/try-bang.yml" <<'YAML'
id: swift.try-bang
language: swift
rule: { pattern: try! $CALL }
severity: critical
message: "try! will crash on error; use try? or do/catch."
YAML

  # as! is almost always a footgun in app code
  cat >"$AST_RULE_DIR/force-cast.yml" <<'YAML'
id: swift.force-cast
language: swift
rule: { pattern: $EXPR as! $T }
severity: warning
message: "Force cast as! may crash at runtime; use as? with guard."
YAML

  cat >"$AST_RULE_DIR/iuo-decl.yml" <<'YAML'
id: swift.implicitly-unwrapped
language: swift
rule:
  any:
    - pattern: let $N: $T!
    - pattern: var $N: $T!
severity: warning
message: "Implicitly unwrapped optional; prefer regular optional and safe binding."
YAML

  cat >"$AST_RULE_DIR/datacontentsof.yml" <<'YAML'
id: swift.data-contents-of
language: swift
rule: { pattern: Data(contentsOf: $URL, $$) }
severity: warning
message: "Data(contentsOf:) is blocking; avoid for remote URLs and large files."
YAML

  cat >"$AST_RULE_DIR/http-literal.yml" <<'YAML'
id: swift.http-literal
language: swift
rule:
  regex: '"http://[^"]+"'
severity: warning
message: "http:// literal detected; prefer https and ATS-compliant networking."
YAML

  cat >"$AST_RULE_DIR/urlsession-task-no-resume.yml" <<'YAML'
id: swift.urlsession.task-no-resume
language: swift
rule:
  pattern: $T = URLSession.$S.$M($ARGS)
  not:
    inside:
      any:
        - pattern: $T.resume()
        - pattern: URLSession.$S.$M($ARGS).resume()
severity: warning
message: "URLSession task created but not resumed."
YAML

  cat >"$AST_RULE_DIR/url-init-http.yml" <<'YAML'
id: swift.url.http-literal
language: swift
rule:
  any:
    - pattern: URL(string: "http://$X")
    - pattern: URL(string: "http://")
    - regex: 'URL\\(string:\\s*"http://[^"]*"\\)'
severity: warning
message: "URL(string:) with http:// literal; prefer https unless ATS exception is justified."
YAML

  cat >"$AST_RULE_DIR/task-floating.yml" <<'YAML'
id: swift.task.floating
language: swift
rule:
  pattern: Task { $BODY }
  not:
    inside:
      any:
        - pattern: let $H = Task { $BODY }
        - pattern: var $H = Task { $BODY }
        - pattern: _ = Task { $BODY }
severity: warning
message: "Unstructured Task launched without keeping a handle."
YAML

  cat >"$AST_RULE_DIR/task-detached.yml" <<'YAML'
id: swift.task.detached-no-handle
language: swift
rule:
  pattern: Task.detached(priority: $P?, operation: $OP)
  not:
    inside:
      any:
        - pattern: let $H = Task.detached(priority: $P?, operation: $OP)
        - pattern: var $H = Task.detached(priority: $P?, operation: $OP)
severity: warning
message: "Task.detached without handle may leak or outlive scope."
YAML

  cat >"$AST_RULE_DIR/withcheckedcontinuation-no-resume.yml" <<'YAML'
id: swift.continuation.no-resume
language: swift
rule:
  pattern: withCheckedContinuation { $C in
    $BODY
  }
  not:
    inside:
      pattern: $C.resume($$)
severity: critical
message: "CheckedContinuation without resume() along all paths."
YAML

  cat >"$AST_RULE_DIR/withunsafecontinuation-no-resume.yml" <<'YAML'
id: swift.unsafecontinuation.no-resume
language: swift
rule:
  pattern: withUnsafeContinuation { $C in
    $BODY
  }
  not:
    inside:
      pattern: $C.resume($$)
severity: critical
message: "UnsafeContinuation without resume() can deadlock."
YAML

  cat >"$AST_RULE_DIR/closure-strong-self-async.yml" <<'YAML'
id: swift.closure.capture-strong-self
language: swift
rule:
  pattern: $API($ARGS) { $PARAMS in
    $BODY
  }
  not:
    any:
      - has: { regex: "\\[\\s*weak\\s+self\\s*\\]" }
      - has: { regex: "\\[\\s*unowned\\s+self\\s*\\]" }
severity: info
message: "Closure may capture self strongly; consider [weak self] for long-lived work."
YAML

  cat >"$AST_RULE_DIR/timer-not-invalidated.yml" <<'YAML'
id: swift.timer.not-invalidated
language: swift
rule:
  pattern: $TM = Timer.scheduledTimer($ARGS)
  not:
    inside:
      pattern: $TM.invalidate()
severity: warning
message: "Timer scheduled but not invalidated in the same scope."
YAML

  cat >"$AST_RULE_DIR/notification-token-not-removed.yml" <<'YAML'
id: swift.notification.token-not-removed
language: swift
rule:
  pattern: let $TOK = NotificationCenter.default.addObserver(forName: $NAME, object: $OBJ, queue: $Q) { $B }
  not:
    inside:
      pattern: NotificationCenter.default.removeObserver($TOK)
severity: warning
message: "Block-based NotificationCenter observer not removed."
YAML

  cat >"$AST_RULE_DIR/combine-sink-no-store.yml" <<'YAML'
id: swift.combine.sink-no-store
language: swift
rule:
  pattern: $PUBLISHER.sink($ARGS)
  not:
    any:
      - inside: { regex: "\\.store\\(in:\\s*&" }
      - inside: { pattern: let $C = $PUBLISHER.sink($ARGS) }
      - inside: { pattern: var $C = $PUBLISHER.sink($ARGS) }
severity: warning
message: "Combine sink without storing AnyCancellable; subscription may cancel immediately."
YAML

  cat >"$AST_RULE_DIR/closure-unowned-self-escaping.yml" <<'YAML'
id: swift.closure.unowned-self-escaping
language: swift
rule:
  pattern: $API($ARGS) { [unowned self] $PARAMS in
    $BODY
  }
severity: warning
message: "Escaping closure capturing unowned self may crash; prefer [weak self] + guard."
YAML

  cat >"$AST_RULE_DIR/fatal-in-nil-coalesce.yml" <<'YAML'
id: swift.nil-coalescing-fatal
language: swift
rule:
  pattern: $X ?? fatalError($MSG)
severity: warning
message: "Using ?? fatalError for control flow; prefer throwing or early returns."
YAML

  cat >"$AST_RULE_DIR/dispatch-main-sync.yml" <<'YAML'
id: swift.dispatch.main.sync
language: swift
rule:
  pattern: DispatchQueue.main.sync { $B }
severity: warning
message: "DispatchQueue.main.sync risks deadlock; prefer async or @MainActor."
YAML

  cat >"$AST_RULE_DIR/print-nslog.yml" <<'YAML'
id: swift.print.nslog
language: swift
rule:
  any:
    - pattern: print($$)
    - pattern: NSLog($$)
severity: info
message: "Print/NSLog found; ensure debug-only or use os.Logger with privacy."
YAML

  cat >"$AST_RULE_DIR/fatal-precondition.yml" <<'YAML'
id: swift.fatal-or-precondition
language: swift
rule:
  any:
    - pattern: fatalError($$)
    - pattern: preconditionFailure($$)
severity: warning
message: "Crash calls present; confirm they are not reachable in production."
YAML

  cat >"$AST_RULE_DIR/commoncrypto-weak.yml" <<'YAML'
id: swift.commoncrypto.weak
language: swift
rule:
  any:
    - regex: "\\bCC_MD5\\b"
    - regex: "\\bCC_SHA1\\b"
severity: warning
message: "Weak hash algorithm (MD5/SHA1) via CommonCrypto."
YAML

  cat >"$AST_RULE_DIR/cryptokit-insecure.yml" <<'YAML'
id: swift.cryptokit.insecure
language: swift
rule:
  any:
    - pattern: Insecure.SHA1($$)
    - pattern: Insecure.MD5($$)
severity: warning
message: "CryptoKit Insecure.* algorithm used; prefer SHA256/512."
YAML

  cat >"$AST_RULE_DIR/userdefaults-secrets.yml" <<'YAML'
id: swift.userdefaults.secrets
language: swift
rule:
  pattern: UserDefaults.$S.set($VAL, forKey: $KEY)
  has:
    regex: "(?i)(password|token|secret|apikey|api_key|authorization|bearer)"
severity: warning
message: "Sensitive-looking value stored in UserDefaults; prefer Keychain."
YAML

  cat >"$AST_RULE_DIR/nsurlsession-delegate-tls.yml" <<'YAML'
id: swift.urlsession.delegate.tls-trust
language: swift
rule:
  regex: "didReceiveChallenge\\s*\\(.*URLAuthenticationChallenge.*\\)\\s*\\{[\\s\\S]*?completionHandler\\s*\\(\\s*\\.useCredential\\s*,\\s*URLCredential\\(trust:"
severity: critical
message: "URLSession delegate trusting server trust directly; TLS pinning bypass risk."
YAML

  cat >"$AST_RULE_DIR/main-thread-sleep.yml" <<'YAML'
id: swift.main-thread.sleep
language: swift
rule:
  pattern: DispatchQueue.main.sync { $BODY }
  has:
    any:
      - regex: "\\bsleep\\("
      - regex: "\\busleep\\("
severity: warning
message: "Blocking sleep on main queue."
YAML

  cat >"$AST_RULE_DIR/dispatchsemaphore-main.yml" <<'YAML'
id: swift.dispatchsemaphore.main
language: swift
rule:
  pattern: DispatchSemaphore(value: $V).wait($$)
  inside:
    pattern: DispatchQueue.main.$M($$) { $BODY }
severity: warning
message: "Semaphore wait on main queue can deadlock."
YAML

  cat >"$AST_RULE_DIR/nsurlconnection-deprecated.yml" <<'YAML'
id: swift.deprecated.nsurlconnection
language: swift
rule:
  any:
    - pattern: NSURLConnection($$)
    - pattern: NSURLConnection.sendSynchronousRequest($$)
severity: info
message: "NSURLConnection deprecated; use URLSession."
YAML

  cat >"$AST_RULE_DIR/uiwebview-deprecated.yml" <<'YAML'
id: swift.deprecated.uiwebview
language: swift
rule:
  any:
    - pattern: UIWebView($$)
    - regex: "\\bUIWebView\\b"
severity: warning
message: "UIWebView is deprecated and banned on App Store; use WKWebView."
YAML

  cat >"$AST_RULE_DIR/as-anyobject.yml" <<'YAML'
id: swift.anyobject-cast
language: swift
rule:
  pattern: $EXPR as AnyObject
severity: info
message: "Casting to AnyObject erases types; avoid unless required by ObjC APIs."
YAML

  cat >"$AST_RULE_DIR/oslogger-privacy.yml" <<'YAML'
id: swift.oslogger.privacy
language: swift
rule:
  pattern: logger.$LEVEL(""\($VAL)"")
  not:
    has:
      regex: "privacy:\\s*\\.private|privacy:\\s*\\.public"
severity: info
message: "os.Logger interpolation without explicit privacy; defaults to private/public depending on platform."
YAML

  cat >"$AST_RULE_DIR/ibaction-iuo.yml" <<'YAML'
id: swift.ibaction.iuo
language: swift
rule:
  pattern: @IBAction func $N($P: $T!) $BODY
severity: info
message: "@IBAction with IUO parameter; prefer non-IUO where possible."
YAML

  cat >"$AST_RULE_DIR/process-shell-injection.yml" <<'YAML'
id: swift.process.shell-injection
language: swift
rule:
  regex: 'Process\\s*\\(\\s*\\)|Process\\s*\\.\\s*launchedProcess|system\\('
severity: info
message: "Process/system invocation present; ensure untrusted input is sanitized."
YAML

  # ── Expanded Swift rules (new) ───────────────────────────────────────────
  cat >"$AST_RULE_DIR/json-decode-try-bang.yml" <<'YAML'
id: swift.json.decode.try-bang
language: swift
rule:
  any:
    - pattern: try! JSONDecoder().decode($T.self, from: $D)
    - pattern: try! decoder.decode($T.self, from: $D)
severity: critical
message: "JSON decode with try! may crash; use do/catch and surface decoding errors."
YAML

  cat >"$AST_RULE_DIR/json-decode-try-q.yml" <<'YAML'
id: swift.json.decode.try-question
language: swift
rule:
  any:
    - pattern: try? JSONDecoder().decode($T.self, from: $D)
    - pattern: try? decoder.decode($T.self, from: $D)
severity: info
message: "Decoding with try? discards errors; ensure this is intentional and logged."
YAML

  cat >"$AST_RULE_DIR/task-sleep-units.yml" <<'YAML'
id: swift.task.sleep.units
language: swift
rule:
  pattern: Task.sleep($N)
  has:
    regex: "Task\\.sleep\\(\\s*[0-9_]+\\s*\\)"
severity: warning
message: "Task.sleep expects nanoseconds; literals like 1 or 2 often indicate seconds confusion."
YAML

  cat >"$AST_RULE_DIR/dispatchgroup-enter-leave.yml" <<'YAML'
id: swift.dispatchgroup.enter-leave.maybe-imbalance
language: swift
rule:
  pattern: $G.enter()
  not:
    inside:
      pattern: $G.leave()
severity: info
message: "DispatchGroup enter() without a nearby leave(); verify balanced usage."
YAML

  cat >"$AST_RULE_DIR/uiimage-named.yml" <<'YAML'
id: swift.uiimage.named
language: swift
rule:
  any:
    - pattern: UIImage(named: $S)
    - pattern: NSImage(named: $S)
severity: info
message: "Image by name; ensure caching or asset catalog usage is correct to avoid repeated loads."
YAML

  cat >"$AST_RULE_DIR/kvc-literal.yml" <<'YAML'
id: swift.kvc.literal
language: swift
rule:
  pattern: $OBJ.setValue($V, forKey: $K)
  has:
    regex: 'forKey:\\s*"[A-Za-z0-9_\\.]+"'
severity: info
message: "KVC string key; prefer typed APIs to avoid runtime key typos."
YAML

  cat >"$AST_RULE_DIR/unsafe-pointer-types.yml" <<'YAML'
id: swift.unsafe.pointer
language: swift
rule:
  regex: "\\bUnsafe(Raw)?(Mutable)?Pointer\\b"
severity: info
message: "Unsafe pointer usage; review for memory safety and lifetime rules."
YAML

  cat >"$AST_RULE_DIR/path-join-string.yml" <<'YAML'
id: swift.path.join.string-plus
language: swift
rule:
  regex: '"\\/"\\s*\\+\\s*[A-Za-z_][A-Za-z0-9_]*'
severity: info
message: "Path building via string concatenation; prefer URL.appendingPathComponent or NSString.path."
YAML

  cat >"$AST_RULE_DIR/urlsession-task-cancel.yml" <<'YAML'
id: swift.urlsession.task-no-cancel-on-deinit
language: swift
rule:
  pattern: let $T = URLSession.$S.$M($ARGS)
  not:
    inside:
      pattern: $T.cancel()
severity: info
message: "URLSession task captured but no cancel() nearby; ensure lifecycle cancellation on teardown."
YAML

  cat >"$AST_RULE_DIR/weak-self-guard.yml" <<'YAML'
id: swift.closure.weak-self.guarded
language: swift
rule:
  pattern: { regex: "\\[\\s*weak\\s+self\\s*\\].*\\{[\\s\\S]*?\\bself\\b[^\\S\\n]*\\." }
  not:
    has: { regex: "guard\\s+let\\s+self\\s*=\\s*self\\s*else\\s*\\{\\s*return\\s*\\}" }
severity: info
message: "weak self captured but no guard self; consider a guarded unwrap for clarity."
YAML
  # Done
}

run_ast_rules() {
  [[ "$HAS_AST_GREP" -eq 1 && -n "$AST_RULE_DIR" ]] || return 1
  if [[ "$FORMAT" == "sarif" ]]; then
    with_timeout "${AST_GREP_CMD[@]}" scan -r "$AST_RULE_DIR" "$PROJECT_DIR" --lang swift --sarif 2>/dev/null || return 1
    AST_PASSTHROUGH=1; return 0
  fi
  if [[ "$FORMAT" == "json" ]]; then
    with_timeout "${AST_GREP_CMD[@]}" scan -r "$AST_RULE_DIR" "$PROJECT_DIR" --lang swift --json 2>/dev/null || return 1
    AST_PASSTHROUGH=1; return 0
  fi
  local tmp_stream; tmp_stream="$(mktemp -t ag_sw_stream.XXXXXX 2>/dev/null || mktemp -t ag_sw_stream)"
  ( set +o pipefail; with_timeout "${AST_GREP_CMD[@]}" scan -r "$AST_RULE_DIR" "$PROJECT_DIR" --lang swift --json=stream 2>/dev/null || true ) >"$tmp_stream"
  if [[ ! -s "$tmp_stream" ]]; then rm -f "$tmp_stream"; return 0; fi
  print_subheader "ast-grep rule-pack summary"
  if command -v python3 >/dev/null 2>&1; then
  python3 - "$tmp_stream" "$DETAIL_LIMIT" <<'PY'
import json, sys, collections
path, limit = sys.argv[1], int(sys.argv[2])
buckets = collections.OrderedDict()
def add(obj):
    rid = obj.get('rule_id') or obj.get('id') or 'unknown'
    sev = (obj.get('severity') or '').lower() or 'info'
    file = obj.get('file','?')
    rng  = obj.get('range') or {}
    ln = (rng.get('start') or {}).get('row',0)+1
    msg = obj.get('message') or rid
    b = buckets.setdefault(rid, {'severity': sev, 'message': msg, 'count': 0, 'samples': []})
    b['count'] += 1
    if len(b['samples']) < limit:
        code = (obj.get('lines') or '').strip().splitlines()[:1]
        b['samples'].append((file, ln, code[0] if code else ''))
with open(path, 'r', encoding='utf-8') as fh:
    for line in fh:
        line=line.strip()
        if not line: continue
        try: add(json.loads(line))
        except: pass
sev_rank = {'critical':0, 'warning':1, 'info':2, 'good':3}
for rid, data in sorted(buckets.items(), key=lambda kv:(sev_rank.get(kv[1]['severity'],9), -kv[1]['count'])):
    sev = data['severity']; cnt=data['count']; title=data['message']
    print(f"__FINDING__\t{sev}\t{cnt}\t{rid}\t{title}")
    for f,l,c in data['samples']:
        s=c.replace('\t',' ').strip()
        print(f"__SAMPLE__\t{f}\t{l}\t{s}")
PY
  else
    # Minimal fallback: one-line per match id
    awk -F'"' '/"rule_id":/ { print "__FINDING__\tinfo\t1\t" $4 "\t(ast-grep match)"}' "$tmp_stream"
  fi
  while IFS=$'\t' read -r tag a b c d; do
    case "$tag" in
      __FINDING__) print_finding "$a" "$(num_clamp "$b")" "$c: $d" ;;
      __SAMPLE__)  print_code_sample "$a" "$b" "$c" ;;
    esac
  done <"$tmp_stream"
  rm -f "$tmp_stream"
  return 0
}

# ────────────────────────────────────────────────────────────────────────────
# Swift-aware helpers
# ────────────────────────────────────────────────────────────────────────────
run_resource_lifecycle_checks() {
  print_subheader "Resource lifecycle correlation (Swift)"
  local helper="$SCRIPT_DIR/helpers/resource_lifecycle_swift.py"
  if [[ -f "$helper" ]] && command -v python3 >/dev/null 2>&1; then
    local output
    if output=$(python3 "$helper" "$PROJECT_DIR" 2>/dev/null); then
      if [[ -z "$output" ]]; then
        print_finding "good" "All tracked resource acquisitions show matching cleanup or usage"
      else
        while IFS=$'\t' read -r location kind message; do
          [[ -z "$location" ]] && continue
          local summary="${RESOURCE_LIFECYCLE_SUMMARY[$kind]:-Resource imbalance}"
          local remediation="${RESOURCE_LIFECYCLE_REMEDIATION[$kind]:-Ensure matching cleanup call}"
          local severity="${RESOURCE_LIFECYCLE_SEVERITY[$kind]:-warning}"
          local detail="$remediation"
          [[ -n "$message" ]] && detail="$message"
          print_finding "$severity" 1 "$summary [$location]" "$detail"
        done <<<"$output"
      fi
      return
    else
      print_finding "info" 0 "AST helper failed" "See stderr for details"
    fi
  else
    if [[ ! -f "$helper" ]]; then
      print_finding "info" 0 "Resource helper missing" "Expected $helper"
    elif ! command -v python3 >/dev/null 2>&1; then
      print_finding "info" 0 "python3 not available" "Install Python 3 to run AST helper"
    fi
  fi

  # Regex fallback
  local rid
  local header_shown=0
  for rid in "${RESOURCE_LIFECYCLE_IDS[@]}"; do
    local acquire_regex="${RESOURCE_LIFECYCLE_ACQUIRE[$rid]:-}"
    local release_regex="${RESOURCE_LIFECYCLE_RELEASE[$rid]:-}"
    [[ -z "$acquire_regex" || -z "$release_regex" ]] && continue
    local file_list
    file_list=$("${GREP_RN[@]}" -e "$acquire_regex" "$PROJECT_DIR" 2>/dev/null | cut -d: -f1 | sort -u || true)
    [[ -n "$file_list" ]] || continue
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      local acquire_hits release_hits
      acquire_hits=$("${GREP_RN[@]}" -e "$acquire_regex" "$file" 2>/dev/null | count_lines || true)
      release_hits=$("${GREP_RN[@]}" -e "$release_regex" "$file" 2>/dev/null | count_lines || true)
      acquire_hits=${acquire_hits:-0}
      release_hits=${release_hits:-0}
      if (( acquire_hits > release_hits )); then
        if [[ $header_shown -eq 0 ]]; then header_shown=1; fi
        local delta=$((acquire_hits - release_hits))
        local relpath=${file#"$PROJECT_DIR"/}; [[ "$relpath" == "$file" ]] && relpath="$file"
        local summary="${RESOURCE_LIFECYCLE_SUMMARY[$rid]:-Resource imbalance}"
        local remediation="${RESOURCE_LIFECYCLE_REMEDIATION[$rid]:-Ensure matching cleanup call}"
        local severity="${RESOURCE_LIFECYCLE_SEVERITY[$rid]:-warning}"
        local desc="$remediation (acquire=$acquire_hits, cleanup=$release_hits)"
        print_finding "$severity" "$delta" "$summary [$relpath]" "$desc"
      fi
    done <<<"$file_list"
  done
  if [[ $header_shown -eq 0 ]]; then
    print_finding "good" "All tracked resource acquisitions have matching cleanups"
  fi
}

run_async_error_checks() {
  print_subheader "Async concurrency coverage"
  if [[ "$HAS_AST_GREP" -ne 1 ]]; then
    print_finding "info" 0 "ast-grep not available" "Install ast-grep to enable concurrency checks"
    return
  fi
  local rule_dir tmp_json
  rule_dir="$(mktemp -d 2>/dev/null || mktemp -d -t swift_async_rules.XXXXXX)"
  if [[ ! -d "$rule_dir" ]]; then
    print_finding "info" 0 "temp dir creation failed" "Unable to stage ast-grep rules"
    return
  fi
  cat >"$rule_dir/swift.task.floating.yml" <<'YAML'
id: swift.task.floating
language: swift
rule:
  pattern: Task { $B }
  not:
    inside:
      any:
        - pattern: let $T = Task { $B }
        - pattern: var $T = Task { $B }
        - pattern: _ = Task { $B }
severity: warning
message: "Unstructured Task launched without handle."
YAML
  cat >"$rule_dir/swift.task.detached-no-handle.yml" <<'YAML'
id: swift.task.detached-no-handle
language: swift
rule:
  pattern: Task.detached(priority: $P?, operation: $OP)
  not:
    inside:
      any:
        - pattern: let $H = Task.detached(priority: $P?, operation: $OP)
        - pattern: var $H = Task.detached(priority: $P?, operation: $OP)
severity: warning
message: "Task.detached without handle or cancellation."
YAML
  cat >"$rule_dir/swift.continuation.no-resume.yml" <<'YAML'
id: swift.continuation.no-resume
language: swift
rule:
  any:
    - pattern: withCheckedContinuation { $C in $B }
    - pattern: withUnsafeContinuation { $C in $B }
  not:
    inside:
      pattern: $C.resume($$)
severity: critical
message: "Continuation used without resume() in body."
YAML

  tmp_json="$(mktemp 2>/dev/null || mktemp -t swift_async_matches.XXXXXX)"
  : >"$tmp_json"
  local rule_file
  for rule_file in "$rule_dir"/*.yml; do
    "${AST_GREP_CMD[@]}" scan -r "$rule_file" "$PROJECT_DIR" --lang swift --json=stream >>"$tmp_json" 2>/dev/null || true
  done
  rm -rf "$rule_dir"
  if ! [[ -s "$tmp_json" ]]; then
    rm -f "$tmp_json"
    print_finding "good" "No obvious unstructured or unsafe concurrency patterns"
    return
  fi
  local printed=0
  while IFS=$'\t' read -r rid count samples; do
    [[ -z "$rid" ]] && continue
    printed=1
    local severity=${ASYNC_ERROR_SEVERITY[$rid]:-warning}
    local summary=${ASYNC_ERROR_SUMMARY[$rid]:-$rid}
    local desc=${ASYNC_ERROR_REMEDIATION[$rid]:-"Fix concurrency misuse"}
    [[ -n "$samples" ]] && desc+=" (e.g., $samples)"
    print_finding "$severity" "$count" "$summary" "$desc"
  done < <(python3 - "$tmp_json" <<'PY'
import json, sys, collections
stats=collections.OrderedDict()
with open(sys.argv[1],'r',encoding='utf-8') as fh:
  for line in fh:
    line=line.strip()
    if not line: continue
    try: obj=json.loads(line)
    except: continue
    rid=obj.get('rule_id') or obj.get('id')
    if not rid: continue
    file=obj.get('file','?'); rng=obj.get('range') or {}
    ln=(rng.get('start') or {}).get('row',0)+1
    b=stats.setdefault(rid,{'count':0,'samples':[]}); b['count']+=1
    if len(b['samples'])<3: b['samples'].append(f"{file}:{ln}")
for rid,data in stats.items():
  print(f"{rid}\t{data['count']}\t{','.join(data['samples'])}")
PY
)
  rm -f "$tmp_json"
  if [[ $printed -eq 0 ]]; then
    print_finding "good" "Async operations appear well-structured"
  fi
}

run_plist_checks() {
  print_subheader "Info.plist ATS precise parsing"
  if command -v python3 >/dev/null 2>&1; then
    local out
    out=$(python3 - "$PROJECT_DIR" <<'PY'
import os, sys, plistlib
root=sys.argv[1]
def check(fp):
  try:
    with open(fp,'rb') as fh:
      pl=plistlib.load(fh)
  except Exception:
    return []
  res=[]
  ats=pl.get('NSAppTransportSecurity') or {}
  if isinstance(ats, dict):
    if ats.get('NSAllowsArbitraryLoads') is True:
      res.append(('warning', fp, 'ATS arbitrary loads enabled', 'NSAllowsArbitraryLoads=true'))
    if ats.get('NSAllowsArbitraryLoadsInWebContent') is True:
      res.append(('info', fp, 'Arbitrary loads in web content', 'NSAllowsArbitraryLoadsInWebContent=true'))
    if ats.get('NSAllowsLocalNetworking') is True:
      res.append(('info', fp, 'Local networking allowed', 'NSAllowsLocalNetworking=true'))
    ex=ats.get('NSExceptionDomains') or {}
    if isinstance(ex, dict):
      for domain,cfg in ex.items():
        if isinstance(cfg, dict):
          if cfg.get('NSExceptionAllowsInsecureHTTPLoads') is True:
            res.append(('warning', fp, f'HTTP allowed for {domain}', 'NSExceptionAllowsInsecureHTTPLoads=true'))
          if cfg.get('NSTemporaryExceptionAllowsInsecureHTTPLoads') is True:
            res.append(('info', fp, f'Temporary HTTP for {domain}', 'NSTemporaryExceptionAllowsInsecureHTTPLoads=true'))
          if cfg.get('NSIncludesSubdomains') is True and (domain.startswith("*.") or domain.startswith("*")):
            res.append(('warning', fp, f'Wildcard subdomain exception {domain}', 'NSIncludesSubdomains with wildcard'))
  return res
acc=[]
for dp,_,files in os.walk(root):
  for n in files:
    if n=="Info.plist":
      acc.extend(check(os.path.join(dp,n)))
for sev,fp,title,detail in acc:
  print(sev+"\t"+fp+"\t"+title+"\t"+detail)
PY
)
    if [[ -n "$out" ]]; then
      while IFS=$'\t' read -r sev file title detail; do
        print_finding "$sev" 1 "$title [$file]" "$detail"
      done <<<"$out"
    else
      print_finding "good" "No problematic ATS settings found via plist parsing"
    fi
  else
    print_finding "info" 0 "python3 not available for ATS parsing" "Using regex heuristics below"
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# Optional analyzers
# ────────────────────────────────────────────────────────────────────────────
run_swiftlint() {
  print_subheader "SwiftLint"
  if command -v swiftlint >/dev/null 2>&1; then
    pushd "$PROJECT_DIR" >/dev/null 2>&1 || true
    with_timeout swiftlint --quiet --reporter json --strict 2>/dev/null || true
    popd >/dev/null 2>&1 || true
  else
    say "  ${GRAY}${INFO} SwiftLint not installed${RESET}"
  fi
}
run_swiftformat() {
  print_subheader "SwiftFormat (lint mode)"
  if command -v swiftformat >/dev/null 2>&1; then
    pushd "$PROJECT_DIR" >/dev/null 2>&1 || true
    with_timeout swiftformat "$PROJECT_DIR" --lint --quiet 2>/dev/null || true
    popd >/dev/null 2>&1 || true
  else
    say "  ${GRAY}${INFO} SwiftFormat not installed${RESET}"
  fi
}
run_periphery() {
  print_subheader "Periphery (dead code)"
  if command -v periphery >/dev/null 2>&1; then
    pushd "$PROJECT_DIR" >/dev/null 2>&1 || true
    with_timeout periphery scan --quiet || true
    popd >/dev/null 2>&1 || true
  else
    say "  ${GRAY}${INFO} Periphery not installed${RESET}"
  fi
}
run_xcodebuild_analyze() {
  print_subheader "xcodebuild analyze (Clang static analyzer)"
  local xcw xcp SCHEME=""
  xcw=$(find "$PROJECT_DIR" -maxdepth 6 -name "*.xcworkspace" | head -n1 || true)
  xcp=$(find "$PROJECT_DIR" -maxdepth 6 -name "*.xcodeproj"    | head -n1 || true)
  local sdkflag=""
  case "$SDK_KIND" in
    ios) sdkflag="-sdk iphonesimulator" ;;
    macos) sdkflag="-sdk macosx" ;;
    tvos) sdkflag="-sdk appletvsimulator" ;;
    watchos) sdkflag="-sdk watchsimulator" ;;
  esac
  if command -v xcodebuild >/dev/null 2>&1; then
    if [[ -n "$xcw" ]]; then
      if command -v python3 >/dev/null 2>&1; then
        SCHEME=$(xcodebuild -list -json -workspace "$xcw" 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); s=(d.get("workspace",{}) or {}).get("schemes") or []; print(s[0] if s else "")' 2>/dev/null)
      fi
      [[ -z "$SCHEME" ]] && SCHEME="$(basename "$xcw" .xcworkspace)"
      with_timeout xcodebuild -workspace "$xcw" -scheme "$SCHEME" analyze $sdkflag 2>/dev/null || true
    elif [[ -n "$xcp" ]]; then
      if command -v python3 >/dev/null 2>&1; then
        SCHEME=$(xcodebuild -list -json -project "$xcp" 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); s=(d.get("project",{}) or {}).get("schemes") or []; print(s[0] if s else "")' 2>/dev/null)
      fi
      [[ -z "$SCHEME" ]] && SCHEME="$(basename "$xcp" .xcodeproj)"
      with_timeout xcodebuild -project "$xcp" -scheme "$SCHEME" analyze $sdkflag 2>/dev/null || true
    else
      say "  ${GRAY}${INFO} No Xcode project/workspace found for analyze${RESET}"
    fi
  else
    say "  ${GRAY}${INFO} xcodebuild not available${RESET}"
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# Category skipping helper
# ────────────────────────────────────────────────────────────────────────────
should_skip() {
  local cat="$1"
  # Allow explicit ONLY list to trump everything
  if [[ -n "$ONLY_CATEGORIES" ]]; then
    local allowed=1
    IFS=',' read -r -a arr <<<"$ONLY_CATEGORIES"
    for s in "${arr[@]}"; do [[ "$s" == "$cat" ]] && allowed=0; done
    [[ $allowed -eq 1 ]] && return 1
  fi
  if [[ -n "$CATEGORY_WHITELIST" ]]; then
    local allowed=1
    IFS=',' read -r -a allow <<<"$CATEGORY_WHITELIST"
    for s in "${allow[@]}"; do [[ "$s" == "$cat" ]] && allowed=0; done
    [[ $allowed -eq 1 ]] && return 1
  fi
  if [[ -z "$SKIP_CATEGORIES" ]]; then return 0; fi
  IFS=',' read -r -a arr <<<"$SKIP_CATEGORIES"
  for s in "${arr[@]}"; do [[ "$s" == "$cat" ]] && return 1; done
  return 0
}

# ────────────────────────────────────────────────────────────────────────────
# Init
# ────────────────────────────────────────────────────────────────────────────
maybe_clear

echo -e "${BOLD}${CYAN}"
cat <<'BANNER'                                                       
╔═══════════════════════════════════════════════════════════════════╗
║  ██╗   ██╗██╗  ████████╗██╗███╗   ███╗ █████╗ ████████╗███████╗   ║
║  ██║   ██║██║  ╚══██╔══╝██║████╗ ████║██╔══██╗╚══██╔══╝██╔════╝   ║
║  ██║   ██║██║     ██║   ██║██╔████╔██║███████║   ██║   █████╗     ║
║  ██║   ██║██║     ██║   ██║██║╚██╔╝██║██╔══██║   ██║   ██╔══╝     ║
║  ╚██████╔╝███████╗██║   ██║██║ ╚═╝ ██║██║  ██║   ██║   ███████╗   ║
║   ╚═════╝ ╚══════╝╚═╝   ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝   ║
║                                      ===========::=====           ║
║  ██████╗ ██╗   ██╗ ██████╗           ===-:=:===== .====           ║
║  ██╔══██╗██║   ██║██╔════╝           =====.::.=++  .===           ║
║  ██████╔╝██║   ██║██║  ███╗          ==++++=    :  .===           ║
║  ██╔══██╗██║   ██║██║   ██║          ==++++++=.    .===           ║
║  ██████╔╝╚██████╔╝╚██████╔╝          ++=. :::       :++           ║
║  ╚═════╝  ╚═════╝  ╚═════╝           +++++-..   .-++:=+           ║
║                                      ******************           ║
║                                                                   ║
║  ███████╗  ██████╗   █████╗ ███╗   ██╗███╗   ██╗███████╗██████╗   ║
║  ██╔════╝  ██╔═══╝  ██╔══██╗████╗  ██║████╗  ██║██╔════╝██╔══██╗  ║
║  ███████╗  ██║      ███████║██╔██╗ ██║██╔██╗ ██║█████╗  ██████╔╝  ║
║  ╚════██║  ██║      ██╔══██║██║╚██╗██║██║╚██╗██║██╔══╝  ██╔══██╗  ║
║  ███████║  ██████╗  ██║  ██║██║ ╚████║██║ ╚████║███████╗██║  ██║  ║
║  ╚══════╝  ╚═════╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝       ║
║                                                                   ║
║  Swift module • optionals, concurrency, URLSession, Combine       ║
║  UBS module: swift • catches force ops & async lifecycle          ║
║  ASCII homage: swift bird                                         ║
║                                                                   ║
║                                                                   ║
║  Night Owl QA                                                     ║
║  “We see bugs before you do.”                                     ║
╚═══════════════════════════════════════════════════════════════════╝
                                                                     
BANNER                                                               
echo -e "${RESET}"                                                   

say "${WHITE}Version:${RESET} ${CYAN}${VERSION}${RESET}"
say "${WHITE}Project:${RESET}  ${CYAN}$PROJECT_DIR${RESET}"
say "${WHITE}Started:${RESET}  ${GRAY}$(eval "$DATE_CMD")${RESET}"

if [[ ! -e "$PROJECT_DIR" ]]; then
  echo -e "${RED}${BOLD}Project path not found:${RESET} ${WHITE}$PROJECT_DIR${RESET}" >&2
  exit 2
fi

resolve_timeout || true

# Count files
EX_PRUNE=()
for d in "${EXCLUDE_DIRS[@]}"; do EX_PRUNE+=( -name "$d" -o ); done
EX_PRUNE=( \( -type d \( "${EX_PRUNE[@]}" -false \) -prune \) )
NAME_EXPR=( \( )
first=1
for e in "${_EXT_ARR[@]}"; do
  if [[ $first -eq 1 ]]; then NAME_EXPR+=( -name "*.${e}" ); first=0
  else NAME_EXPR+=( -o -name "*.${e}" ); fi
done
NAME_EXPR+=( \) )
if [[ "$HAS_RIPGREP" -eq 1 ]]; then
  TOTAL_FILES=$(
    ( set +o pipefail; rg --files "$PROJECT_DIR" "${RG_EXCLUDES[@]}" "${RG_INCLUDES[@]}" "${RG_MAX_SIZE_FLAGS[@]}" 2>/dev/null || true ) \
    | wc -l | awk '{print $1+0}'
  )
else
  TOTAL_FILES=$(
    ( set +o pipefail; find "$PROJECT_DIR" "${EX_PRUNE[@]}" -o \( -type f "${NAME_EXPR[@]}" -print \) 2>/dev/null || true ) \
    | wc -l | awk '{print $1+0}'
  )
fi
say "${WHITE}Files:${RESET}    ${CYAN}$TOTAL_FILES source files (${INCLUDE_EXT})${RESET}"

echo ""
if check_ast_grep; then
  say "${GREEN}${CHECK} ast-grep available (${AST_GREP_CMD[*]}) - full AST analysis enabled${RESET}"
  write_ast_rules || true
else
  say "${YELLOW}${WARN} ast-grep unavailable - using regex fallback mode${RESET}"
fi

# ────────────────────────────────────────────────────────────────────────────
# MACHINE-READABLE MODES: early pass-through and exit
# ────────────────────────────────────────────────────────────────────────────
if [[ "$FORMAT" == "json" || "$FORMAT" == "sarif" ]]; then
  if [[ "$HAS_AST_GREP" -ne 1 ]]; then
    echo "${RED}${BOLD}ast-grep is required for --format=$FORMAT${RESET}" >&2
    exit 2
  fi
  tmp_out="$(mktemp -t ubs_ast_${FORMAT}.XXXXXX)"; trap 'rm -f "$tmp_out" 2>/dev/null || true' EXIT
  if [[ "$FORMAT" == "json" ]]; then
    with_timeout "${AST_GREP_CMD[@]}" scan -r "$AST_RULE_DIR" "$PROJECT_DIR" --lang swift --json=stream >"$tmp_out" 2>/dev/null || true
    # stdout: compact JSON array for easy piping
    python3 - <<'PY' "$tmp_out"
import json,sys
with open(sys.argv[1],'r',encoding='utf-8') as fh:
  items=[json.loads(l) for l in fh if l.strip()]
print(json.dumps(items, ensure_ascii=False))
PY
    # compute severities for exit code & optional summary
    read -r CRITICAL_COUNT WARNING_COUNT INFO_COUNT <<EOF
$( (command -v python3 >/dev/null 2>&1 && python3 - <<'PY' "$tmp_out") || echo "0 0 0"
import json,sys,collections
c=w=i=0
with open(sys.argv[1],'r',encoding='utf-8') as fh:
  for line in fh:
    if not line.strip(): continue
    try:
      o=json.loads(line); sev=(o.get('severity') or 'info').lower()
    except: continue
    if sev=='critical': c+=1
    elif sev=='warning': w+=1
    else: i+=1
print(c,w,i)
PY
 )
  else
    with_timeout "${AST_GREP_CMD[@]}" scan -r "$AST_RULE_DIR" "$PROJECT_DIR" --lang swift --sarif >"$tmp_out" 2>/dev-null || true
    cat "$tmp_out"
    # best-effort severity extraction for exit code
    read -r CRITICAL_COUNT WARNING_COUNT INFO_COUNT <<EOF
$(python3 - <<'PY' "$tmp_out"
import json,sys
try:
  sar=json.load(open(sys.argv[1],'r',encoding='utf-8'))
except: print("0 0 0"); sys.exit(0)
runs=sar.get("runs") or []
levels=[]
for r in runs:
  for res in (r.get("results") or []):
    levels.append(((res.get("level") or "note").lower()))
crit=sum(1 for x in levels if x in ("error","critical"))
warn=sum(1 for x in levels if x in ("warning"))
info=len(levels)-crit-warn
print(crit, warn, info)
PY
)
  fi
  # optional run summary file
  if [[ -n "$SUMMARY_JSON" ]]; then
    {
      printf '{"project":%q,"files":%s,"critical":%s,"warning":%s,"info":%s,"timestamp":%q,"format":%q,"sdk":%q}\n' \
        "$PROJECT_DIR" "$TOTAL_FILES" "$CRITICAL_COUNT" "$WARNING_COUNT" "$INFO_COUNT" "$(eval "$DATE_CMD")" "$FORMAT" "$SDK_KIND"
    } > "$SUMMARY_JSON" 2>/dev/null || true
  fi
  EXIT_CODE=0
  if [ "$CRITICAL_COUNT" -gt 0 ]; then EXIT_CODE=1; fi
  if [ "$FAIL_ON_WARNING" -eq 1 ] && [ $((CRITICAL_COUNT + WARNING_COUNT)) -gt 0 ]; then EXIT_CODE=1; fi
  exit "$EXIT_CODE"
fi

# ────────────────────────────────────────────────────────────────────────────
# Scanning begins
# ────────────────────────────────────────────────────────────────────────────
begin_scan_section

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 1: OPTIONALS / FORCE OPERATIONS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 1; then
set_category 1
print_header "1. OPTIONALS / FORCE OPERATIONS"
print_category "Detects: force unwrap (!), try!, as!, IUO declarations" \
  "Avoid crashes by binding optionals and using safe casts/errors."

print_subheader "Force unwrap (!) occurrences"
count=$("${GREP_RN[@]}" -e "![^=]" "$PROJECT_DIR" 2>/dev/null | (grep -v -E "!!|!==" || true) | count_lines || true)
if [ "$count" -gt 30 ]; then
  print_finding "warning" "$count" "Heavy use of force unwrap"
  show_detailed_finding "![^=]" 5
elif [ "$count" -gt 0 ]; then
  print_finding "info" "$count" "Some force unwraps present"
fi

print_subheader "try! and as! occurrences"
# don't use -w for try!
trybang=$("${GREP_RN[@]}" -e "try!" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
asbang=$("${GREP_RN[@]}" -e " as![[:space:]]" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$trybang" -gt 0 ]; then print_finding "critical" "$trybang" "try! used"; show_detailed_finding "try!" 5; else print_finding "good" "No try!"; fi
if [ "$asbang" -gt 0 ]; then print_finding "warning" "$asbang" "as! used"; show_detailed_finding " as![[:space:]]" 5; fi

print_subheader "Implicitly unwrapped optionals (T!)"
iuo=$("${GREP_RN[@]}" -e "(:|->)[[:space:]]*[A-Za-z_][A-Za-z0-9_<>?:\.\[\] ]*!\\b" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$iuo" -gt 0 ]; then print_finding "warning" "$iuo" "Implicitly unwrapped optionals"; show_detailed_finding "(:|->)[[:space:]]*[A-Za-z_][A-Za-z0-9_<>?:\.\[\] ]*!\\b" 5; else print_finding "good" "No IUO types"; fi

print_subheader "Swift guard let validation"
run_swift_type_narrowing_checks
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 2: CONCURRENCY / TASK
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 2; then
set_category 2
print_header "2. CONCURRENCY / TASK"
print_category "Detects: floating tasks, detached tasks without handle, continuations without resume" \
  "Structured concurrency avoids leaks and deadlocks."

task_count=$("${GREP_RNW[@]}" "Task" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
async_count=$("${GREP_RN[@]}" -e "async[[:space:]]+\\b" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
await_count=$("${GREP_RNW[@]}" "await" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
print_finding "info" "$task_count" "Task usages"
if [ "$async_count" -gt "$await_count" ]; then
  diff=$((async_count - await_count)); [ "$diff" -lt 0 ] && diff=0
  print_finding "info" "$diff" "Possible un-awaited async paths"
fi

print_subheader "withChecked/UnsafeContinuation without resume"
cont=$("${GREP_RN[@]}" -e "with(Checked|Unsafe)Continuation[[:space:]]*\{" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$cont" -gt 0 ]; then
  print_finding "info" "$cont" "Continuation sites found" "Ensuring resume() is called exactly once"
fi
run_async_error_checks
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 3: CLOSURES / CAPTURE LISTS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 3; then
set_category 3
print_header "3. CLOSURES / CAPTURE LISTS"
print_category "Detects: strong self in long-lived closures, unowned self hazards" \
  "Use [weak self] where closures outlive self; prefer guard let self."

print_subheader "Long-lived closures without [weak self]"
count=$("${GREP_RN[@]}" -e "(URLSession\.|DispatchQueue\.global|DispatchQueue\.main|Timer\.scheduledTimer|NotificationCenter\.default\.addObserver|UIView\.animate|NSAnimationContext\.runAnimationGroup)" "$PROJECT_DIR" 2>/dev/null \
  | (grep -A3 -E "\{[[:space:]]*(\\[[^]]*\\])?" || true) \
  | (grep -v -i "\[weak self\]" || true) \
  | count_lines
if [ "$count" -gt 0 ]; then
  print_finding "warning" "$count" "Potential strong self captures in long-lived closures" "Consider capture list [weak self]"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 4: URLSESSION / NETWORKING
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 4; then
set_category 4
print_header "4. URLSESSION / NETWORKING"
print_category "Detects: tasks not resumed, http literals, Data(contentsOf:), insecure trust handlers" \
  "Networking bugs cause hangs, security issues, and battery drain."

print_subheader "URLSession tasks not resumed"
count=$("${GREP_RN[@]}" -e "URLSession\.[A-Za-z_]+\.(dataTask|uploadTask|downloadTask)\(" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v "\.resume\(\)" || true) | count_lines)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "URLSession tasks lacking resume()"; fi

print_subheader "http:// literals"
count=$("${GREP_RN[@]}" -e "\"http://[^\"]+\"" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "http:// URLs"; show_detailed_finding "\"http://[^\"]+\"" 5; else print_finding "good" "No http:// literals"; fi

print_subheader "URL(string:) with http://"
count=$("${GREP_RN[@]}" -e "URL\\(string:\\s*\"http://[^\"]*\"" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "URL(string:) http literal"; fi

print_subheader "Blocking Data(contentsOf:)"
count=$("${GREP_RN[@]}" -e "Data\(contentsOf:" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Data(contentsOf:) usage may block"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 5: ERROR HANDLING
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 5; then
set_category 5
print_header "5. ERROR HANDLING"
print_category "Detects: empty catches, do/catch that swallows, fatalError misuse" \
  "Handle errors or propagate with throws."

print_subheader "Empty catches / ignored errors"
count=$("${GREP_RN[@]}" -e "catch[[:space:]]*\{[[:space:]]*\}" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Empty catch blocks"; show_detailed_finding "catch[[:space:]]*\{[[:space:]]*\}" 5; else print_finding "good" "No empty catch blocks"; fi

print_subheader "try? discarding errors"
count=$("${GREP_RN[@]}" -e "try\?[[:space:]]*[A-Za-z_\(]" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 30 ]; then print_finding "info" "$count" "Many try? sites - verify error handling strategy"; fi

print_subheader "fatalError/preconditionFailure presence"
count=$("${GREP_RN[@]}" -e "fatalError\(|preconditionFailure\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Crash sites"; show_detailed_finding "fatalError\(|preconditionFailure\(" 5; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 6: SECURITY
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 6; then
set_category 6
print_header "6. SECURITY"
print_category "Detects: trust-all URLSession delegate, hardcoded secrets, shell Process misuse" \
  "Security bugs expose users and violate policies."

print_subheader "Trust-all server trust delegates"
count=$("${GREP_RN[@]}" -e "didReceiveChallenge\(.*URLAuthenticationChallenge.*\)" "$PROJECT_DIR" 2>/dev/null | \
  (grep -E "useCredential|URLCredential\(trust:" || true) | count_lines )
if [ "$count" -gt 0 ]; then print_finding "critical" "$count" "URLSession delegate accepts any trust"; fi

print_subheader "Hardcoded secrets"
count=$("${GREP_RNI[@]}" -e "(password|api_?key|secret|token)[[:space:]]*[:=][[:space:]]*\"[^\"]+\"" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "critical" "$count" "Hardcoded secret lookalikes"; show_detailed_finding "(password|api_?key|secret|token)[[:space:]]*[:=][[:space:]]*\"[^\"]+\"" 5; else print_finding "good" "No obvious hardcoded secrets"; fi

print_subheader "Process/posix shell usage"
count=$("${GREP_RN[@]}" -e "Process\(|posix_spawn|system\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "info" "$count" "Shell/process invocation present - validate inputs"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 7: CRYPTO / HASHING
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 7; then
set_category 7
print_header "7. CRYPTO / HASHING"
print_category "Detects: weak algorithms via CommonCrypto & CryptoKit Insecure.*" \
  "Prefer SHA-256/512 and authenticated encryption."

print_subheader "CommonCrypto MD5/SHA1"
count=$("${GREP_RN[@]}" -e "CC_MD5|CC_SHA1" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Weak hashing use"; show_detailed_finding "CC_MD5|CC_SHA1" 5; else print_finding "good" "No CommonCrypto MD5/SHA1"; fi

print_subheader "CryptoKit Insecure.*"
count=$("${GREP_RN[@]}" -e "Insecure\.SHA1|Insecure\.MD5" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "CryptoKit Insecure algorithms"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 8: FILES & I/O
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 8; then
set_category 8
print_header "8. FILES & I/O"
print_category "Detects: FileHandle leaks, blocking reads, path string concat" \
  "Use URL and ensure closing handles."

print_subheader "FileHandle open without close in file"
count=$("${GREP_RN[@]}" -e "FileHandle\(for(Read|Write|Updating)[^)]*\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
closecount=$("${GREP_RN[@]}" -e "\.close\(\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ] && [ "$closecount" -lt "$count" ]; then
  diff=$((count - closecount)); [ "$diff" -lt 0 ] && diff=0
  print_finding "warning" "$diff" "FileHandle open without matching close"
fi

print_subheader "Path string concatenation"
count=$("${GREP_RN[@]}" -e "\"/\"\\s*\\+" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 10 ]; then print_finding "info" "$count" "String path join - use URL(fileURLWithPath:) or appendingPathComponent"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 9: THREADING / MAIN
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 9; then
set_category 9
print_header "9. THREADING / MAIN"
print_category "Detects: UI updates off main, sleeps/semaphores on main" \
  "UI work must happen on the main actor."

print_subheader "Explicit MainActor annotation missing (heuristic)"
ui_files=$("${GREP_RN[@]}" -e "UIKit|AppKit|SwiftUI" "$PROJECT_DIR" 2>/dev/null | cut -d: -f1 | sort -u | count_lines || true)
mainactor_annots=$("${GREP_RN[@]}" -e "@MainActor" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$ui_files" -gt 0 ] && [ "$mainactor_annots" -eq 0 ]; then
  print_finding "info" "$ui_files" "UI frameworks used but no @MainActor annotations found"
fi

print_subheader "sleep/usleep on main queue"
count=$("${GREP_RN[@]}" -e "DispatchQueue\.main\.(async|sync)\s*\{\s*[^}]*sleep\(|usleep\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "sleep on main queue"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 10: PERFORMANCE
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 10; then
set_category 10
print_header "10. PERFORMANCE"
print_category "Detects: String += in loops, regex compile in loops, N^2 patterns" \
  "Avoid obvious performance anti-patterns."

print_subheader "String concatenation in loops"
count=$("${GREP_RN[@]}" -e "for[[:space:]]+[^:]+in[[:space:]]+[^:]+:[[:space:]]*$" "$PROJECT_DIR" 2>/dev/null | \
  (grep -A4 "\+=" || true) | (grep -cw "\+=" || true))
count=$(printf '%s\n' "$count" | awk 'END{print $0+0}')
if [ "$count" -gt 5 ]; then print_finding "info" "$count" "String += in loops - consider join/builders"; fi

print_subheader "NSRegularExpression init in loops"
count=$("${GREP_RN[@]}" -e "for[[:space:]].*in.*\{[[:space:][:graph:]]*$" "$PROJECT_DIR" 2>/dev/null | \
  (grep -A6 "NSRegularExpression\\(" || true) | (grep -cw "NSRegularExpression" || true))
count=$(printf '%s\n' "$count" | awk 'END{print $0+0}')
if [ "$count" -gt 0 ]; then print_finding "info" "$count" "Regex compiled inside loop"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 11: DEBUG / PRODUCTION
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 11; then
set_category 11
print_header "11. DEBUG / PRODUCTION"
print_category "Detects: print/NSLog, debug flags, assertions" \
  "Ensure debug artifacts are stripped from release."

print_subheader "print/NSLog occurrences"
count=$("${GREP_RN[@]}" -e "^[[:space:]]*print\(|NSLog\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 50 ]; then print_finding "warning" "$count" "Many print/NSLog calls"; elif [ "$count" -gt 10 ]; then print_finding "info" "$count" "print/NSLog present"; else print_finding "good" "Minimal print/NSLog"; fi

print_subheader "assert(false) or assertionFailure()"
count=$("${GREP_RN[@]}" -e "assert\(false\)|assertionFailure\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Assertions that always fail"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 12: REGEX
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 12; then
set_category 12
print_header "12. REGEX"
print_category "Detects: nested quantifiers (ReDoS), untrusted pattern construction" \
  "Regex bugs cause performance issues."

print_subheader "Nested quantifiers (potential catastrophic backtracking)"
count=$("${GREP_RN[@]}" -e "NSRegularExpression\(pattern:[^)]*(\\+\\+|\\*\\+|\\+\\*|\\*\\*)[^)]*\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 1 ]; then print_finding "warning" "$count" "Potential catastrophic regex"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 13: SWIFTUI / COMBINE
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 13; then
set_category 13
print_header "13. SWIFTUI / COMBINE"
print_category "Detects: sink without store, .onReceive leaks, @State misuse" \
  "State management must retain subscriptions and avoid cycles."

print_subheader "Combine .sink without .store(in:)"
count=$("${GREP_RN[@]}" -e "\\.sink\\(" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v "\\.store\\(in:" || true) | count_lines)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Combine sinks not stored"; fi

print_subheader "SwiftUI onReceive capturing self without weak"
count=$("${GREP_RN[@]}" -e "\\.onReceive\\(" "$PROJECT_DIR" 2>/dev/null | \
  (grep -A2 -E "\\{[[:space:]]*value" || true) | (grep -v -i "\\[weak self\\]" || true) | count_lines )
if [ "$count" -gt 0 ]; then print_finding "info" "$count" "onReceive without [weak self] (heuristic)"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 14: MEMORY / RETAIN
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 14; then
set_category 14
print_header "14. MEMORY / RETAIN"
print_category "Detects: retain cycles via Timer/Notification/closures" \
  "Break cycles with weak references or invalidation."

print_subheader "Timer scheduled without invalidation"
count=$("${GREP_RN[@]}" -e "Timer\.scheduledTimer" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v "invalidate\(" || true) | count_lines)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Timers without invalidate heuristic"; fi

print_subheader "NotificationCenter block-based without removal"
count=$("${GREP_RN[@]}" -e "addObserver\\(forName:" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v "removeObserver" || true) | count_lines)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Observer tokens not removed"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 15: CODE QUALITY MARKERS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 15; then
set_category 15
print_header "15. CODE QUALITY MARKERS"
print_category "Detects: TODO, FIXME, HACK, XXX, NOTE" \
  "Technical debt markers indicate work remaining."

todo=$("${GREP_RNI[@]}" "TODO" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
fixme=$("${GREP_RNI[@]}" "FIXME" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
hack=$("${GREP_RNI[@]}" "HACK" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
xxx=$("${GREP_RNI[@]}" "XXX" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
total=$((todo + fixme + hack + xxx))
if [ "$total" -gt 20 ]; then print_finding "warning" "$total" "Significant technical debt"
elif [ "$total" -gt 10 ]; then print_finding "info" "$total" "Moderate technical debt"
elif [ "$total" -gt 0 ]; then print_finding "info" "$total" "Minimal technical debt"
else print_finding "good" "No technical debt markers"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 16: RESOURCE LIFECYCLE
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 16; then
set_category 16
print_header "16. RESOURCE LIFECYCLE"
print_category "Detects: Timer/URLSessionTask/Notification tokens/FileHandle/Combine/DispatchSource cleanups" \
  "Unreleased resources leak memory, file descriptors, or tasks."

run_resource_lifecycle_checks
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 17: INFO.PLIST / ATS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 17; then
set_category 17
print_header "17. INFO.PLIST / ATS"
print_category "Detects: NSAppTransportSecurity exceptions, arbitrary loads" \
  "ATS exceptions require justification; avoid blanket disables."
run_plist_checks

print_subheader "ATS allows arbitrary loads"
count=$("${GREP_RN[@]}" -e "NSAppTransportSecurity|NSAllowsArbitraryLoads" "$PROJECT_DIR" 2>/dev/null | \
  (grep -E "true|YES" || true) | count_lines)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "ATS arbitrary loads enabled"; fi

print_subheader "NSAllowsArbitraryLoadsInWebContent"
count=$("${GREP_RN[@]}" -e "NSAllowsArbitraryLoadsInWebContent" "$PROJECT_DIR" 2>/dev/null | \
  (grep -E "true|YES" || true) | count_lines)
if [ "$count" -gt 0 ]; then print_finding "info" "$count" "Arbitrary loads in web content enabled"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 18: DEPRECATED APIs
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 18; then
set_category 18
print_header "18. DEPRECATED APIs"
print_category "Detects: UIWebView/NSURLConnection, deprecated status bar APIs, old Reachability" \
  "Remove deprecated APIs before submission."

print_subheader "UIWebView/NSURLConnection"
count=$("${GREP_RN[@]}" -e "UIWebView|NSURLConnection" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Deprecated networking/webview APIs"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 19: BUILD / SIGNING
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 19; then
set_category 19
print_header "19. BUILD / SIGNING"
print_category "Detects: entitlements anomalies, debug signing in release, Hardened Runtime (macOS)" \
  "Ensure secure build settings."

print_subheader "Debug signing identifiers in Release configs (heuristic)"
count=$("${GREP_RN[@]}" -e "PROVISIONING_PROFILE_SPECIFIER|CODE_SIGN_IDENTITY" "$PROJECT_DIR" 2>/dev/null | \
  (grep -i "debug" || true) | count_lines )
if [ "$count" -gt 0 ]; then print_finding "info" "$count" "Debug-like signing strings detected"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 20: PACKAGING / SPM
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 20; then
set_category 20
print_header "20. PACKAGING / SPM"
print_category "Detects: unpinned SPM packages, branch deps, local paths" \
  "Pin dependencies for reproducibility."

print_subheader "Package.swift with branch or revision pins"
if [ -f "$PROJECT_DIR/Package.swift" ]; then
  count=$(grep -nE '\.branch\(|\.revision\(' "$PROJECT_DIR/Package.swift" 2>/dev/null | count_lines || true)
  if [ "$count" -gt 0 ]; then print_finding "info" "$count" "Branch/revision-based SPM dependencies"; fi
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 21: UI/UX SAFETY
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 21; then
set_category 21
print_header "21. UI/UX SAFETY"
print_category "Detects: force unwrap IBOutlets, large storyboards, accessibility placeholders" \
  "Prefer safe IBOutlets and modular storyboards."

print_subheader "IBOutlet IUO (T!)"
count=$("${GREP_RN[@]}" -e "@IBOutlet[[:space:]]+weak[[:space:]]+var[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[^!]*!" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "info" "$count" "@IBOutlet implicitly unwrapped"; fi

print_subheader "Large storyboards (heuristic)"
count=$(( $(find "$PROJECT_DIR" -name "*.storyboard" 2>/dev/null | wc -l || echo 0) ))
if [ "$count" -gt 5 ]; then print_finding "info" "$count" "Many storyboards - consider modularization"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 22: TESTS / HYGIENE
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 22; then
set_category 22
print_header "22. TESTS / HYGIENE"
print_category "Detects: XCTFail placeholders, sleeps in tests, unfulfilled expectations" \
  "Stable tests avoid sleeps and assert properly."

print_subheader "XCTFail(\"TODO\")"
count=$("${GREP_RN[@]}" -e "XCTFail\\(\"TODO" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "info" "$count" "Placeholder XCTFail"; fi

print_subheader "sleep/usleep in tests"
count=$("${GREP_RN[@]}" -e "XCTestCase|XCT" "$PROJECT_DIR" 2>/dev/null | \
  (grep -A3 -E "sleep\(|usleep\(" || true) | (grep -cw "sleep\(|usleep\(" || true))
count=$(printf '%s\n' "$count" | awk 'END{print $0+0}')
if [ "$count" -gt 0 ]; then print_finding "info" "$count" "Sleep in tests - use expectations"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 23: LOCALIZATION / INTERNATIONALIZATION
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 23; then
set_category 23
print_header "23. LOCALIZATION / INTERNATIONALIZATION"
print_category "Detects: user-facing strings without NSLocalizedString, number/date format risks" \
  "Localize strings and use locale-aware formatters."

print_subheader "Hard-coded user-facing strings (heuristic)"
count=$("${GREP_RN[@]}" -e "UILabel\\(|setTitle\\(|Text\\(\"" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v "NSLocalizedString" || true) | count_lines )
if [ "$count" -gt 0 ]; then print_finding "info" "$count" "Possible user-facing strings without localization"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# AST-GREP RULE PACK
# ═══════════════════════════════════════════════════════════════════════════
print_header "AST-GREP RULE PACK FINDINGS"
if [[ "$HAS_AST_GREP" -eq 1 && -n "$AST_RULE_DIR" ]]; then
  if run_ast_rules; then
    if [[ "$AST_PASSTHROUGH" -eq 1 ]]; then
      say "${DIM}${INFO} Above JSON/SARIF lines are ast-grep matches (id, message, severity, file/pos).${RESET}"
    fi
  else
    say "${YELLOW}${WARN} ast-grep scan subcommand unavailable; rule-pack mode skipped.${RESET}"
  fi
else
  say "${YELLOW}${WARN} ast-grep not available; rule pack skipped.${RESET}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# OPTIONAL ANALYZERS
# ═══════════════════════════════════════════════════════════════════════════
print_header "OPTIONAL ANALYZERS (if installed)"
resolve_timeout || true
run_swiftlint
run_swiftformat
run_periphery
run_xcodebuild_analyze

# Restore strict mode
end_scan_section

# ═══════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
echo ""
say "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════════════════${RESET}"
say "${BOLD}${CYAN}                    🎯 SCAN COMPLETE 🎯                                  ${RESET}"
say "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════════════════${RESET}"
echo ""

say "${WHITE}${BOLD}Summary Statistics:${RESET}"
say "  ${WHITE}Files scanned:${RESET}    ${CYAN}$TOTAL_FILES${RESET}"
say "  ${RED}${BOLD}Critical issues:${RESET}  ${RED}$CRITICAL_COUNT${RESET}"
say "  ${YELLOW}Warning issues:${RESET}   ${YELLOW}$WARNING_COUNT${RESET}"
say "  ${BLUE}Info items:${RESET}       ${BLUE}$INFO_COUNT${RESET}"
echo ""

if [[ -n "$BASELINE" && -f "$BASELINE" ]]; then
  say "${BOLD}${WHITE}Baseline Comparison:${RESET}"
  CRITICAL_COUNT="$CRITICAL_COUNT" WARNING_COUNT="$WARNING_COUNT" INFO_COUNT="$INFO_COUNT" python3 - "$BASELINE" <<'PY'
import json,sys,os
try:
  with open(sys.argv[1],'r',encoding='utf-8') as fh:
    b=json.load(fh)
except Exception:
  print("  (could not read baseline)")
  sys.exit(0)
def get(k):
  try: return int(b.get(k,0))
  except: return 0
from_now={'critical':int(os.environ.get('CRITICAL_COUNT',0)),
          'warning':int(os.environ.get('WARNING_COUNT',0)),
          'info':int(os.environ.get('INFO_COUNT',0))}
for k in ['critical','warning','info']:
  prior=get(k); now=from_now[k]; delta=now-prior
  arrow = '↑' if delta>0 else ('↓' if delta<0 else '→')
  print(f"  {k.capitalize():<8}: {now:>4}  (baseline {prior:>4})  {arrow} {delta:+}")
PY
fi

say "${BOLD}${WHITE}Priority Actions:${RESET}"
if [ "$CRITICAL_COUNT" -gt 0 ]; then
  say "  ${RED}${FIRE} ${BOLD}FIX CRITICAL ISSUES IMMEDIATELY${RESET}"
  say "  ${DIM}These cause crashes, security vulnerabilities, or deadlocks${RESET}"
fi
if [ "$WARNING_COUNT" -gt 0 ]; then
  say "  ${YELLOW}${WARN} ${BOLD}Review and fix WARNING items${RESET}"
  say "  ${DIM}These cause bugs, performance issues, or maintenance problems${RESET}"
fi
if [ "$INFO_COUNT" -gt 0 ]; then
  say "  ${BLUE}${INFO} ${BOLD}Consider INFO suggestions${RESET}"
  say "  ${DIM}Code quality improvements and best practices${RESET}"
fi

if [[ -n "$SUMMARY_JSON" ]]; then
  {
    printf '{'
    printf '"project":"%s",' "$(printf %s "$PROJECT_DIR" | sed 's/"/\\"/g')"
    printf '"files":%s,' "$TOTAL_FILES"
    printf '"critical":%s,' "$CRITICAL_COUNT"
    printf '"warning":%s,' "$WARNING_COUNT"
    printf '"info":%s,' "$INFO_COUNT"
    printf '"timestamp":"%s",' "$(eval "$DATE_CMD")"
    printf '"format":"%s",' "$FORMAT"
    printf '"sdk":"%s",' "$SDK_KIND"
    printf '"categories":{'
    # Expanded per-category export including severity breakdown
    for i in $(seq 1 23); do
      eval "t=\${CAT${i}:-0}"; eval "c=\${CAT${i}_critical:-0}"; eval "w=\${CAT${i}_warning:-0}"; eval "n=\${CAT${i}_info:-0}"
      printf '"%d":{"total":%s,"critical":%s,"warning":%s,"info":%s}' "$i" "$(num_clamp "$t")" "$(num_clamp "$c")" "$(num_clamp "$w")" "$(num_clamp "$n")"
      if [[ $i -lt 23 ]]; then printf ','; fi
    done
    printf '},'
    if [[ -n "$AST_RULE_DIR" && "$HAS_AST_GREP" -eq 1 ]]; then
      printf '"ast_grep_rules":['
      ( set +o pipefail; with_timeout "${AST_GREP_CMD[@]}" scan -r "$AST_RULE_DIR" "$PROJECT_DIR" --lang swift --json=stream 2>/dev/null || true ) \
        | python3 - <<'PY'
import json,sys,collections
seen=collections.Counter()
for line in sys.stdin:
  line=line.strip()
  if not line: continue
  try: rid=(json.loads(line).get('rule_id') or 'unknown'); seen[rid]+=1
  except: pass
print(",".join(json.dumps({"id":k,"count":v}) for k,v in seen.items()))
PY
      printf ']'
    else printf '"ast_grep_rules":[]'; fi
    printf '}\n'
  } > "$SUMMARY_JSON" 2>/dev/null || true
  say "${DIM}Summary JSON written to: ${SUMMARY_JSON}${RESET}"
fi

echo ""
say "${DIM}Scan completed at: $(eval "$DATE_CMD")${RESET}"

if [[ -n "$OUTPUT_FILE" ]]; then
  say "${GREEN}${CHECK} Full report saved to: ${CYAN}$OUTPUT_FILE${RESET}"
fi

echo ""
if [ "$VERBOSE" -eq 0 ]; then
  say "${DIM}Tip: Run with -v/--verbose for more code samples per finding.${RESET}"
fi
say "${DIM}Add to CI: ./ubs-swift --ci --fail-on-warning --summary-json=.ubs-swift-summary.json . > swift-bug-scan-report.txt${RESET}"
echo ""

EXIT_CODE=0
if [ "$CRITICAL_COUNT" -gt 0 ]; then EXIT_CODE=1; fi
if [ "$FAIL_ON_WARNING" -eq 1 ] && [ $((CRITICAL_COUNT + WARNING_COUNT)) -gt 0 ]; then EXIT_CODE=1; fi
exit "$EXIT_CODE"
