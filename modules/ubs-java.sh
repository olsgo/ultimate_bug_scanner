#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# JAVA ULTIMATE BUG SCANNER v1.0 - Industrial-Grade Java 21+ Code Analysis
# ═══════════════════════════════════════════════════════════════════════════
# Comprehensive static analysis for Java using ast-grep + semantic patterns
# + build-tool checks (Maven/Gradle), formatting/lint integrations (optional)
# Focus: Null/Optional pitfalls, equals/hashCode, concurrency/async, security,
# I/O/resources, performance, regex/strings, serialization, code quality.
#
# Features:
#   - Colorful, CI-friendly TTY output with NO_COLOR support
#   - Robust find/rg search with include/exclude globs
#   - Heuristics + AST rule packs (Java) written on-the-fly
#   - JSON/SARIF passthrough from ast-grep rule scans
#   - Category skip/selection, verbosity, sample snippets
#   - Parallel jobs for ripgrep
#   - Exit on critical or optionally on warnings
#   - Optional Maven/Gradle compile + lint task runners (best-effort)
# ═══════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail
shopt -s lastpipe
shopt -s extglob

# ────────────────────────────────────────────────────────────────────────────
# Error trapping
# ────────────────────────────────────────────────────────────────────────────
on_err() {
  local ec=$?; local cmd=${BASH_COMMAND}; local line=${BASH_LINENO[0]}; local src=${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}
  echo -e "\n${RED}${BOLD}Unexpected error (exit $ec)${RESET} ${DIM}at ${src}:${line}${RESET}\n${DIM}Last command:${RESET} ${WHITE}$cmd${RESET}" >&2
  exit "$ec"
}
trap on_err ERR

# ────────────────────────────────────────────────────────────────────────────
# Color / Icons
# ────────────────────────────────────────────────────────────────────────────
USE_COLOR=1
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then USE_COLOR=0; fi

if [[ "$USE_COLOR" -eq 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;90m'
  BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; WHITE=''; GRAY=''
  BOLD=''; DIM=''; RESET=''
fi

CHECK="✓"; CROSS="✗"; WARN="⚠"; INFO="ℹ"; ARROW="→"; BULLET="•"; MAGNIFY="🔍"; BUG="🐛"; FIRE="🔥"; SPARKLE="✨"; SHIELD="🛡"; WRENCH="🛠"; ROCKET="🚀"

# ────────────────────────────────────────────────────────────────────────────
# CLI Parsing & Configuration
# ────────────────────────────────────────────────────────────────────────────
VERBOSE=0
PROJECT_DIR="."
OUTPUT_FILE=""
FORMAT="text"          # text|json|sarif (text implemented; ast-grep emits json/sarif in rule-pack mode)
CI_MODE=0
FAIL_ON_WARNING=0
INCLUDE_EXT="java"
QUIET=0
NO_COLOR_FLAG=0
EXTRA_EXCLUDES=""
SKIP_CATEGORIES=""
DETAIL_LIMIT=3
MAX_DETAILED=250
JOBS="${JOBS:-0}"
USER_RULE_DIR=""
DISABLE_PIPEFAIL_DURING_SCAN=1

RUN_BUILD=1
JAVA_REQUIRED_MAJOR=21
JAVA_VERSION_STR=""
JAVA_MAJOR=0

print_usage() {
  cat >&2 <<USAGE
Usage: $(basename "$0") [options] [PROJECT_DIR] [OUTPUT_FILE]

Options:
  -v, --verbose              More code samples per finding (DETAIL=10)
  -q, --quiet                Reduce non-essential output
  --format=FMT               Output format: text|json|sarif (default: text)
  --ci                       CI mode (stable timestamps, no screen clear)
  --no-color                 Force disable ANSI color
  --include-ext=CSV          File extensions (default: java)
  --exclude=GLOB[,..]        Additional glob(s)/dir(s) to exclude
  --jobs=N                   Parallel jobs for ripgrep (default: auto)
  --skip=CSV                 Skip categories by number (e.g. --skip=2,7,11)
  --fail-on-warning          Exit non-zero on warnings or critical
  --rules=DIR                Additional ast-grep rules directory (merged)
  --no-build                 Skip Maven/Gradle compile/lint tasks
  -h, --help                 Show help

Env:
  JOBS, NO_COLOR, CI

Args:
  PROJECT_DIR                Directory to scan (default: ".")
  OUTPUT_FILE                File to save the report (optional)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; DETAIL_LIMIT=10; shift;;
    -q|--quiet)   VERBOSE=0; DETAIL_LIMIT=1; QUIET=1; shift;;
    --format=*)   FORMAT="${1#*=}"; shift;;
    --ci)         CI_MODE=1; shift;;
    --no-color)   NO_COLOR_FLAG=1; shift;;
    --include-ext=*) INCLUDE_EXT="${1#*=}"; shift;;
    --exclude=*)  EXTRA_EXCLUDES="${1#*=}"; shift;;
    --jobs=*)     JOBS="${1#*=}"; shift;;
    --skip=*)     SKIP_CATEGORIES="${1#*=}"; shift;;
    --fail-on-warning) FAIL_ON_WARNING=1; shift;;
    --rules=*)    USER_RULE_DIR="${1#*=}"; shift;;
    --no-build)   RUN_BUILD=0; shift;;
    -h|--help)    print_usage; exit 0;;
    *)
      if [[ "$PROJECT_DIR" == "." && ! "$1" =~ ^- ]]; then
        PROJECT_DIR="$1"; shift
      elif [[ -z "$OUTPUT_FILE" && ! "$1" =~ ^- ]]; then
        OUTPUT_FILE="$1"; shift
      else
        echo "Unexpected argument: $1" >&2; exit 2
      fi;;
  esac
done

if [[ -n "${CI:-}" ]]; then CI_MODE=1; fi
if [[ "$NO_COLOR_FLAG" -eq 1 ]]; then USE_COLOR=0; fi
if [[ -n "${OUTPUT_FILE}" ]]; then exec > >(tee "${OUTPUT_FILE}") 2>&1; fi

DATE_FMT='%Y-%m-%d %H:%M:%S'
if [[ "$CI_MODE" -eq 1 ]]; then DATE_CMD="date -u '+%Y-%m-%dT%H:%M:%SZ'"; else DATE_CMD="date '+$DATE_FMT'"; fi

# ────────────────────────────────────────────────────────────────────────────
# Global counters
# ────────────────────────────────────────────────────────────────────────────
CRITICAL_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0
TOTAL_FILES=0

# ────────────────────────────────────────────────────────────────────────────
# Global state
# ────────────────────────────────────────────────────────────────────────────
HAS_AST_GREP=0
AST_GREP_CMD=()
AST_RULE_DIR=""
HAS_RG=0

HAS_JAVA=0
HAS_MAVEN=0
HAS_GRADLE=0
GRADLEW=""
MVNW=""
JAVA_TOOLCHAIN_OK=0

# ────────────────────────────────────────────────────────────────────────────
# Search engine configuration (rg if available, else grep)
# ────────────────────────────────────────────────────────────────────────────
LC_ALL=C
IFS=',' read -r -a _EXT_ARR <<<"$INCLUDE_EXT"
INCLUDE_GLOBS=()
for e in "${_EXT_ARR[@]}"; do INCLUDE_GLOBS+=( "--include=*.$(echo "$e" | xargs)" ); done

EXCLUDE_DIRS=(target build out .gradle .idea .vscode .git .settings .mvn .generated node_modules dist coverage .cache .hg .svn .DS_Store)
if [[ -n "$EXTRA_EXCLUDES" ]]; then IFS=',' read -r -a _X <<<"$EXTRA_EXCLUDES"; EXCLUDE_DIRS+=("${_X[@]}"); fi
EXCLUDE_FLAGS=()
for d in "${EXCLUDE_DIRS[@]}"; do EXCLUDE_FLAGS+=( "--exclude-dir=$d" ); done

if command -v rg >/dev/null 2>&1; then
  HAS_RG=1
  if [[ "${JOBS}" -eq 0 ]]; then JOBS="$( (command -v nproc >/dev/null && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 0 )"; fi
  RG_JOBS=(); if [[ "${JOBS}" -gt 0 ]]; then RG_JOBS=(-j "$JOBS"); fi
  RG_BASE=(--no-config --no-messages --line-number --with-filename --hidden "${RG_JOBS[@]}")
  RG_EXCLUDES=()
  for d in "${EXCLUDE_DIRS[@]}"; do RG_EXCLUDES+=( -g "!$d/**" ); done
  RG_INCLUDES=()
  for e in "${_EXT_ARR[@]}"; do RG_INCLUDES+=( -g "*.$(echo "$e" | xargs)" ); done
  GREP_RN=(rg "${RG_BASE[@]}" "${RG_EXCLUDES[@]}" "${RG_INCLUDES[@]}")
  GREP_RNI=(rg -i "${RG_BASE[@]}" "${RG_EXCLUDES[@]}" "${RG_INCLUDES[@]}")
  GREP_RNW=(rg -w "${RG_BASE[@]}" "${RG_EXCLUDES[@]}" "${RG_INCLUDES[@]}")
else
  GREP_R_OPTS=(-R --binary-files=without-match "${EXCLUDE_FLAGS[@]}" "${INCLUDE_GLOBS[@]}")
  GREP_RN=("grep" "${GREP_R_OPTS[@]}" -n -E)
  GREP_RNI=("grep" "${GREP_R_OPTS[@]}" -n -i -E)
  GREP_RNW=("grep" "${GREP_R_OPTS[@]}" -n -w -E)
fi

count_lines() { awk 'END{print (NR+0)}'; }

maybe_clear() { if [[ -t 1 && "$CI_MODE" -eq 0 ]]; then clear || true; fi; }
say() { [[ "$QUIET" -eq 1 ]] && return 0; echo -e "$*"; }

print_header() {
  say "\n${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  say "${WHITE}${BOLD}$1${RESET}"
  say "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

print_category() {
  say "\n${MAGENTA}${BOLD}▓▓▓ $1${RESET}"
  say "${DIM}$2${RESET}"
}

print_subheader() { say "\n${YELLOW}${BOLD}$BULLET $1${RESET}"; }

print_finding() {
  local severity=$1
  case $severity in
    good)
      local title=$2
      say "  ${GREEN}${CHECK} OK${RESET} ${DIM}$title${RESET}"
      ;;
    *)
      local raw_count=$2; local title=$3; local description="${4:-}"
      local count; count=$(printf '%s\n' "$raw_count" | awk 'END{print $0+0}')
      case $severity in
        critical)
          CRITICAL_COUNT=$((CRITICAL_COUNT + count))
          say "  ${RED}${BOLD}${FIRE} CRITICAL${RESET} ${WHITE}($count found)${RESET}"
          say "    ${RED}${BOLD}$title${RESET}"
          [ -n "$description" ] && say "    ${DIM}$description${RESET}" || true
          ;;
        warning)
          WARNING_COUNT=$((WARNING_COUNT + count))
          say "  ${YELLOW}${WARN} Warning${RESET} ${WHITE}($count found)${RESET}"
          say "    ${YELLOW}$title${RESET}"
          [ -n "$description" ] && say "    ${DIM}$description${RESET}" || true
          ;;
        info)
          INFO_COUNT=$((INFO_COUNT + count))
          say "  ${BLUE}${INFO} Info${RESET} ${WHITE}($count found)${RESET}"
          say "    ${BLUE}$title${RESET}"
          [ -n "$description" ] && say "    ${DIM}$description${RESET}" || true
          ;;
      esac
      ;;
  esac
}

print_code_sample() {
  local file=$1; local line=$2; local code=$3
  say "${GRAY}      $file:$line${RESET}"
  say "${WHITE}      $code${RESET}"
}

show_detailed_finding() {
  local pattern=$1; local limit=${2:-$DETAIL_LIMIT}; local printed=0
  while IFS=: read -r file line code; do
    print_code_sample "$file" "$line" "$code"; printed=$((printed+1))
    [[ $printed -ge $limit || $printed -ge $MAX_DETAILED ]] && break
  done < <("${GREP_RN[@]}" -e "$pattern" "$PROJECT_DIR" 2>/dev/null | head -n "$limit" || true) || true
}

show_ast_examples() {
  local pattern=$1; local limit=${2:-$DETAIL_LIMIT}; local printed=0
  if [[ "$HAS_AST_GREP" -eq 1 ]]; then
    while IFS=: read -r file line col rest; do
      local code=""
      if [[ -f "$file" && -n "$line" ]]; then code="$(sed -n "${line}p" "$file" | sed $'s/\t/  /g')"; fi
      print_code_sample "$file" "$line" "${code:-$rest}"
      printed=$((printed+1)); [[ $printed -ge $limit || $printed -ge $MAX_DETAILED ]] && break
    done < <( ( set +o pipefail; "${AST_GREP_CMD[@]}" --lang java --pattern "$pattern" -n "$PROJECT_DIR" 2>/dev/null || true ) | head -n "$limit" )
  fi
}

begin_scan_section(){
  if [[ "$DISABLE_PIPEFAIL_DURING_SCAN" -eq 1 ]]; then set +o pipefail; fi
  set +e
  trap - ERR
}
end_scan_section(){
  trap on_err ERR
  set -e
  if [[ "$DISABLE_PIPEFAIL_DURING_SCAN" -eq 1 ]]; then set -o pipefail; fi
}

# ────────────────────────────────────────────────────────────────────────────
# Tool detection
# ────────────────────────────────────────────────────────────────────────────
check_ast_grep() {
  if command -v ast-grep >/dev/null 2>&1; then AST_GREP_CMD=(ast-grep); HAS_AST_GREP=1; return 0; fi
  if command -v sg       >/dev/null 2>&1; then AST_GREP_CMD=(sg);       HAS_AST_GREP=1; return 0; fi
  say "${YELLOW}${WARN} ast-grep not found. Advanced AST checks will be limited.${RESET}"
  say "${DIM}Tip: cargo install ast-grep  or  npm i -g @ast-grep/cli${RESET}"
  HAS_AST_GREP=0; return 1
}

check_java_env() {
  if command -v java >/dev/null 2>&1; then HAS_JAVA=1; JAVA_VERSION_STR="$(java -version 2>&1 | head -n1)"; fi
  local javac_str; javac_str="$(javac -version 2>&1 || true)"
  if [[ -z "$JAVA_VERSION_STR" && -n "$javac_str" ]]; then JAVA_VERSION_STR="$javac_str"; fi
  local ver
  ver="$( (echo "$JAVA_VERSION_STR" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo '') )"
  if [[ -z "$ver" ]]; then ver="$(echo "$JAVA_VERSION_STR" | grep -oE '[0-9]+' | head -n1)"; fi
  JAVA_MAJOR="$(echo "$ver" | awk -F. '{print $1+0}')"
  if [[ "$JAVA_MAJOR" -ge "$JAVA_REQUIRED_MAJOR" ]]; then JAVA_TOOLCHAIN_OK=1; fi

  [[ -f "$PROJECT_DIR/mvnw" && -x "$PROJECT_DIR/mvnw" ]] && MVNW="$PROJECT_DIR/mvnw"
  [[ -f "$PROJECT_DIR/gradlew" && -x "$PROJECT_DIR/gradlew" ]] && GRADLEW="$PROJECT_DIR/gradlew"
  if command -v mvn >/dev/null 2>&1 || [[ -n "$MVNW" ]]; then HAS_MAVEN=1; fi
  if command -v gradle >/dev/null 2>&1 || [[ -n "$GRADLEW" ]]; then HAS_GRADLE=1; fi
}

# ────────────────────────────────────────────────────────────────────────────
# ast-grep helpers
# ────────────────────────────────────────────────────────────────────────────
ast_search() {
  local pattern=$1
  if [[ "$HAS_AST_GREP" -eq 1 ]]; then
    ( set +o pipefail; "${AST_GREP_CMD[@]}" --lang java --pattern "$pattern" "$PROJECT_DIR" 2>/dev/null || true ) | wc -l | awk '{print $1+0}'
  else
    return 1
  fi
}

write_ast_rules() {
  [[ "$HAS_AST_GREP" -eq 1 ]] || return 0
  AST_RULE_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t ag_rules.XXXXXX)"
  trap '[[ -n "${AST_RULE_DIR:-}" ]] && rm -rf "$AST_RULE_DIR" || true' EXIT
  if [[ -n "$USER_RULE_DIR" && -d "$USER_RULE_DIR" ]]; then
    cp -R "$USER_RULE_DIR"/. "$AST_RULE_DIR"/ 2>/dev/null || true
  fi

  # ====== General panic-prone / debug ======
  cat >"$AST_RULE_DIR/printStackTrace.yml" <<'YAML'
id: java.print-stacktrace
language: java
rule:
  pattern: $E.printStackTrace()
severity: warning
message: "printStackTrace() leaks sensitive details; use a logger"
YAML

  cat >"$AST_RULE_DIR/println.yml" <<'YAML'
id: java.system-println
language: java
rule:
  any:
    - pattern: System.out.println($$)
    - pattern: System.err.println($$)
severity: info
message: "System.out/err.println detected; prefer structured logging"
YAML

  # ====== Optional / Null ======
  cat >"$AST_RULE_DIR/optional-get.yml" <<'YAML'
id: java.optional-get
language: java
rule:
  pattern: $O.get()
severity: warning
message: "Optional.get() may throw NoSuchElementException; prefer orElse, orElseThrow, or ifPresent"
YAML

  # ====== Equality / Collections ======
  cat >"$AST_RULE_DIR/string-eq-operator.yml" <<'YAML'
id: java.string-eq-operator
language: java
rule:
  any:
    - pattern: $X == $Y
      constraints:
        X:
          kind: string_literal
    - pattern: $X == $Y
      constraints:
        Y:
          kind: string_literal
severity: warning
message: "String compared with '=='; use equals()/Objects.equals()"
YAML

  cat >"$AST_RULE_DIR/bigdecimal-equals.yml" <<'YAML'
id: java.bigdecimal-equals
language: java
rule:
  pattern: $BD.equals($OTHER)
  inside:
    pattern: BigDecimal $BD_NAME = $BD_EXPR;
severity: info
message: "BigDecimal.equals checks scale; prefer compareTo() == 0 for numeric equality"
YAML

  # ====== Concurrency ======
  cat >"$AST_RULE_DIR/synchronized-this.yml" <<'YAML'
id: java.synchronized-this
language: java
rule:
  pattern: synchronized(this) { $$ }
severity: info
message: "synchronized(this) exposes lock to external code; prefer private lock"
YAML

  cat >"$AST_RULE_DIR/thread-start.yml" <<'YAML'
id: java.thread-start
language: java
rule:
  pattern: new Thread($$).start()
severity: info
message: "Manual Thread management; consider executors or virtual threads in Java 21+"
YAML

  cat >"$AST_RULE_DIR/executors-cached.yml" <<'YAML'
id: java.executors-cached
language: java
rule:
  pattern: java.util.concurrent.Executors.newCachedThreadPool($$)
severity: warning
message: "newCachedThreadPool has unbounded threads; ensure backpressure"
YAML

  cat >"$AST_RULE_DIR/thread-sleep-in-sync.yml" <<'YAML'
id: java.thread-sleep-in-synchronized
language: java
rule:
  pattern: synchronized($L) { $$ java.lang.Thread.sleep($D); $$ }
severity: info
message: "Thread.sleep inside synchronized block may block other threads unnecessarily"
YAML

  cat >"$AST_RULE_DIR/notify.yml" <<'YAML'
id: java.notify
language: java
rule:
  pattern: $O.notify()
severity: info
message: "notify() wakes a single waiter; ensure this is intended (notifyAll?)"
YAML

  # ====== Security ======
  cat >"$AST_RULE_DIR/insecure-random.yml" <<'YAML'
id: java.insecure-random
language: java
rule:
  pattern: new java.util.Random($$)
severity: info
message: "java.util.Random is not cryptographically secure; prefer SecureRandom for secrets"
YAML

  cat >"$AST_RULE_DIR/trust-all-cert.yml" <<'YAML'
id: java.insecure-ssl
language: java
rule:
  any:
    - pattern: javax.net.ssl.HttpsURLConnection.setDefaultHostnameVerifier(($H, $S) -> true)
    - pattern: $X.setHostnameVerifier(($H, $S) -> true)
    - pattern: new javax.net.ssl.X509TrustManager { $$ public void checkServerTrusted($$, $$) { } $$ }
severity: critical
message: "SSL/TLS verification disabled; enables MITM"
YAML

  cat >"$AST_RULE_DIR/weak-hash.yml" <<'YAML'
id: java.weak-hash
language: java
rule:
  any:
    - pattern: java.security.MessageDigest.getInstance("MD5")
    - pattern: java.security.MessageDigest.getInstance("SHA-1")
severity: warning
message: "Weak hash algorithm detected (MD5/SHA-1); prefer SHA-256/512"
YAML

  cat >"$AST_RULE_DIR/plain-http.yml" <<'YAML'
id: java.plain-http
language: java
rule:
  pattern: "http://$REST"
severity: info
message: "Plain HTTP URL detected; ensure HTTPS for production"
YAML

  cat >"$AST_RULE_DIR/deserialization.yml" <<'YAML'
id: java.insecure-deserialization
language: java
rule:
  any:
    - pattern: new java.io.ObjectInputStream($$).readObject()
    - pattern: $IN.readObject()
severity: warning
message: "Java deserialization can be dangerous; validate types or avoid if possible"
YAML

  # ====== I/O & Charset ======
  cat >"$AST_RULE_DIR/inputstreamreader-no-charset.yml" <<'YAML'
id: java.inputstreamreader-no-charset
language: java
rule:
  pattern: new java.io.InputStreamReader($S)
severity: info
message: "InputStreamReader without explicit charset uses platform default; specify charset"
YAML

  cat >"$AST_RULE_DIR/string-no-charset.yml" <<'YAML'
id: java.string-bytes-no-charset
language: java
rule:
  any:
    - pattern: new String($B)
    - pattern: $S.getBytes()
severity: info
message: "String/bytes without charset; specify StandardCharsets.UTF_8 (or required encoding)"
YAML

  # ====== Streams / Parallel ======
  cat >"$AST_RULE_DIR/parallel-foreach.yml" <<'YAML'
id: java.parallel-foreach-side-effects
language: java
rule:
  pattern: $SRC.parallel().forEach($$)
severity: info
message: "parallel().forEach may reorder and run side effects concurrently; ensure thread-safety"
YAML

  # ====== Reflection ======
  cat >"$AST_RULE_DIR/reflection.yml" <<'YAML'
id: java.reflection
language: java
rule:
  any:
    - pattern: Class.forName($$)
    - pattern: $C.getDeclaredField($$)
    - pattern: $C.getDeclaredMethod($$)
    - pattern: $M.invoke($$)
    - pattern: $F.setAccessible(true)
severity: info
message: "Reflection reduces type safety; ensure strict validation"
YAML

  # ====== Regex ======
  cat >"$AST_RULE_DIR/regex-nested-quant.yml" <<'YAML'
id: java.regex-redos
language: java
rule:
  pattern: "((.*\\+.*)\\+)|((.*\\*.*)\\+)"
severity: warning
message: "Regex with nested quantifiers; potential ReDoS"
YAML

  # ====== Collections / Legacy ======
  cat >"$AST_RULE_DIR/legacy-collections.yml" <<'YAML'
id: java.legacy-collections
language: java
rule:
  any:
    - pattern: new java.util.Vector($$)
    - pattern: new java.util.Hashtable($$)
severity: info
message: "Legacy synchronized collections; prefer java.util.concurrent alternatives"
YAML

  # ====== Virtual threads / Structured Concurrency (Java 21+) ======
  cat >"$AST_RULE_DIR/virtual-threads.yml" <<'YAML'
id: java.virtual-threads
language: java
rule:
  any:
    - pattern: java.lang.Thread.ofVirtual().start($$)
    - pattern: java.lang.Thread.ofVirtual().factory()
    - pattern: new jdk.internal.vm.Continuation($$)
severity: info
message: "Virtual threads detected; ensure blocking I/O is appropriate or use async APIs"
YAML
}

run_ast_rules() {
  [[ "$HAS_AST_GREP" -eq 1 && -n "$AST_RULE_DIR" ]] || return 1
  local outfmt="--json"; [[ "$FORMAT" == "sarif" ]] && outfmt="--sarif"
  "${AST_GREP_CMD[@]}" scan -r "$AST_RULE_DIR" "$PROJECT_DIR" $outfmt 2>/dev/null
}

# ────────────────────────────────────────────────────────────────────────────
# Build helpers (Maven/Gradle best-effort)
# ────────────────────────────────────────────────────────────────────────────
run_cmd_log() {
  local logfile="$1"; shift
  local ec=0
  ( set +e; "$@" >"$logfile" 2>&1; ec=$?; echo "$ec" >"$logfile.ec"; exit 0 )
}

count_warnings_errors_text() {
  local file="$1"
  local w e
  w=$(grep -E "^[Ww]arning: |: warning:|\\bWARNING\\b" "$file" 2>/dev/null | wc -l | awk '{print $1+0}')
  e=$(grep -E "^[Ee]rror: |: error:|\\bERROR\\b" "$file" 2>/dev/null | wc -l | awk '{print $1+0}')
  echo "$w $e"
}

detect_gradle_tasks() {
  local tlist="$1"
  local grep_task; grep_task() { grep -q -E "^\s*$1\s" "$tlist"; }
  GREP_TASK_FN="grep_task"
}

# ────────────────────────────────────────────────────────────────────────────
# Category skipping helper
# ────────────────────────────────────────────────────────────────────────────
should_skip() {
  local cat="$1"
  if [[ -z "$SKIP_CATEGORIES" ]]; then return 0; fi
  IFS=',' read -r -a arr <<<"$SKIP_CATEGORIES"
  for s in "${arr[@]}"; do [[ "$s" == "$cat" ]] && return 1; done
  return 0
}

# ────────────────────────────────────────────────────────────────────────────
# Startup banner
# ────────────────────────────────────────────────────────────────────────────
maybe_clear
echo -e "${BOLD}${CYAN}"
cat <<'BANNER'
╔════════════════════════════════════════════════════════════════════╗
║  ██╗   ██╗██╗  ████████╗██╗███╗   ███╗ █████╗ ████████╗███████╗    ║
║  ██║   ██║██║  ╚══██╔══╝██║████╗ ████║██╔══██╗╚══██╔══╝██╔════╝    ║
║  ██║   ██║██║     ██║   ██║██╔████╔██║███████║   ██║   █████╗      ║
║  ██║   ██║██║     ██║   ██║██║╚██╔╝██║██╔══██║   ██║   ██╔══╝      ║
║  ╚██████╔╝███████╗██║   ██║██║ ╚═╝ ██║██║  ██║   ██║   ███████╗    ║
║   ╚═════╝ ╚══════╝╚═╝   ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝    ║
║                                            (  )   (   )  )         ║
║  ██████╗ ██╗   ██╗ ██████╗                  ) (   )  (  (          ║
║  ██╔══██╗██║   ██║██╔════╝                  ( )  (    ) )          ║
║  ██████╔╝██║   ██║██║  ███╗                 _____________          ║
║  ██╔══██╗██║   ██║██║   ██║                <_____________> ___     ║
║  ██████╔╝╚██████╔╝╚██████╔╝                |             |/ _ \    ║
║  ╚═════╝  ╚═════╝  ╚═════╝                 |               | | |   ║
║                                            |               |_| |   ║
║                                         ___|             |\___/    ║
║                                        /    \___________/    \     ║
║                                        \_____________________/     ║
║                                                                    ║
║  ███████╗  ██████╗   █████╗ ███╗   ██╗███╗   ██╗███████╗██████╗    ║
║  ██╔════╝  ██╔═══╝  ██╔══██╗████╗  ██║████╗  ██║██╔════╝██╔══██╗   ║
║  ███████╗  ██║      ███████║██╔██╗ ██║██╔██╗ ██║█████╗  ██████╔╝   ║
║  ╚════██║  ██║      ██╔══██║██║╚██╗██║██║╚██╗██║██╔══╝  ██╔══██╗   ║
║  ███████║  ██████╗  ██║  ██║██║ ╚████║██║ ╚████║███████╗██║  ██║   ║
║  ╚══════╝  ╚═════╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝        ║
║                                                                    ║
║  Java module • nullability, concurrency, serialization checks      ║
║  UBS module: java • Maven/Gradle compile + AST security packs      ║
║  ASCII homage: ASCII coffee cup (Art Archive)                      ║
║  Run standalone: modules/ubs-java.sh --help                        ║
║                                                                    ║
║  Night Owl QA                                                      ║
║  “We see bugs before you do.”                                      ║
╚════════════════════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"

say "${WHITE}Project:${RESET}  ${CYAN}$PROJECT_DIR${RESET}"
say "${WHITE}Started:${RESET}  ${GRAY}$(eval "$DATE_CMD")${RESET}"

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
TOTAL_FILES=$(
  ( set +o pipefail; find "$PROJECT_DIR" "${EX_PRUNE[@]}" -o \( -type f "${NAME_EXPR[@]}" -print \) 2>/dev/null || true ) \
  | wc -l | awk '{print $1+0}'
)
say "${WHITE}Files:${RESET}    ${CYAN}$TOTAL_FILES source files (${INCLUDE_EXT})${RESET}"

# Tool detection
echo ""
if check_ast_grep; then
  say "${GREEN}${CHECK} ast-grep available (${AST_GREP_CMD[*]}) - full AST analysis enabled${RESET}"
  write_ast_rules || true
else
  say "${YELLOW}${WARN} ast-grep unavailable - using regex-only heuristics where needed${RESET}"
fi

check_java_env
if [[ "$HAS_JAVA" -eq 1 ]]; then
  say "${GREEN}${CHECK} Java detected:${RESET} ${DIM}$JAVA_VERSION_STR${RESET}"
  if [[ "$JAVA_TOOLCHAIN_OK" -ne 1 ]]; then
    say "${YELLOW}${WARN} Java major version $JAVA_MAJOR < $JAVA_REQUIRED_MAJOR; some rules assume Java 21 semantics${RESET}"
  else
    say "${GREEN}${CHECK} Java 21+ toolchain suitable${RESET}"
  fi
else
  say "${YELLOW}${WARN} java/javac not found on PATH; build checks may be skipped${RESET}"
fi
[[ "$HAS_MAVEN" -eq 1 ]]  && say "  ${GREEN}${CHECK}${RESET} Maven available"
[[ "$HAS_GRADLE" -eq 1 ]] && say "  ${GREEN}${CHECK}${RESET} Gradle available"
[[ -n "$MVNW" ]]          && say "  ${BLUE}${INFO}${RESET} Using wrapper: ${CYAN}$MVNW${RESET}"
[[ -n "$GRADLEW" ]]       && say "  ${BLUE}${INFO}${RESET} Using wrapper: ${CYAN}$GRADLEW${RESET}"

# relax pipefail for scanning
begin_scan_section

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 1: NULL & OPTIONAL PITFALLS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 1; then
print_header "1. NULL & OPTIONAL PITFALLS"
print_category "Detects: Optional.get(), == null checks misuse, Objects.equals opportunities" \
  "Unnecessary NPEs and Optional misuse are common sources of production failures"

print_subheader "Optional.get() usage (potential NoSuchElementException)"
opt_get_ast=$(ast_search '$O.get()' || echo 0)
opt_get_rg=$("${GREP_RN[@]}" -e "\.get\(\)" "$PROJECT_DIR" 2>/dev/null | (grep -vE "\.map|\.get\(|\.getClass" || true) | count_lines || true)
opt_total=$(( opt_get_ast>0?opt_get_ast:opt_get_rg ))
if [ "$opt_total" -gt 0 ]; then
  print_finding "warning" "$opt_total" "Optional.get() detected" "Prefer orElse/orElseThrow or ifPresent"
  show_detailed_finding "\.get\(\)" 5
else
  print_finding "good" "No Optional.get() calls"
fi

print_subheader "Null checks using '==' with Strings (prefer Objects.equals)"
str_eq_null=$("${GREP_RN[@]}" -e "==[[:space:]]*null|null[[:space:]]*==" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$str_eq_null" -gt 0 ]; then print_finding "info" "$str_eq_null" "Null equality checks present - consider Objects.isNull/nonNull where expressive"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 2: EQUALITY & HASHCODE
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 2; then
print_header "2. EQUALITY & HASHCODE"
print_category "Detects: String '==' compares, BigDecimal equals(), equals/hashCode mismatch" \
  "Equality issues cause subtle logic bugs and inconsistent collections behavior"

print_subheader "String compared with '=='"
str_eq_ast=$(ast_search '$X == $Y' || echo 0)
str_eq_lit=$("${GREP_RN[@]}" -e "==[[:space:]]*\"|\"[[:space:]]*==" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$str_eq_lit" -gt 0 ]; then print_finding "warning" "$str_eq_lit" "String compared with '=='" "Use equals() or Objects.equals(a,b)"; show_detailed_finding "==[[:space:]]*\"|\"[[:space:]]*==" 5; else print_finding "good" "No String '==' comparisons detected"; fi

print_subheader "BigDecimal.equals vs compareTo"
bd_eq=$("${GREP_RN[@]}" -e "BigDecimal" "$PROJECT_DIR" 2>/dev/null | (grep -E "\.equals\(" || true) | count_lines || true)
if [ "$bd_eq" -gt 0 ]; then print_finding "info" "$bd_eq" "BigDecimal.equals usage - consider compareTo()==0"; fi

print_subheader "equals() overridden without hashCode()"
while IFS= read -r f; do
  eqc=$(grep -nE "boolean[[:space:]]+equals\s*\(" "$f" 2>/dev/null | wc -l | awk '{print $1+0}')
  hcc=$(grep -nE "int[[:space:]]+hashCode\s*\(" "$f" 2>/dev/null | wc -l | awk '{print $1+0}')
  if [ "$eqc" -gt 0 ] && [ "$hcc" -eq 0 ]; then
    print_finding "warning" 1 "equals without hashCode in $f" "Objects used in HashMap/Set will misbehave"
    print_code_sample "$f" "$(grep -nE 'boolean[[:space:]]+equals\s*\(' "$f" | head -n1 | cut -d: -f1)" "equals(...) missing hashCode()"
  fi
done < <(find "$PROJECT_DIR" -type f \( -name "*.java" \) -print 2>/dev/null)
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 3: CONCURRENCY & THREADING
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 3; then
print_header "3. CONCURRENCY & THREADING"
print_category "Detects: synchronized(this), Thread.start, newCachedThreadPool, sleep in synchronized, notify()" \
  "Concurrency misuse leads to deadlocks and performance issues"

print_subheader "synchronized(this) blocks"
syn_this=$(( $(ast_search 'synchronized(this) { $$ }' || echo 0) + $("${GREP_RN[@]}" -e "synchronized\s*\(\s*this\s*\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$syn_this" -gt 0 ]; then print_finding "info" "$syn_this" "synchronized(this) used - prefer private lock objects"; fi

print_subheader "Manual thread management"
thr_start=$(( $(ast_search 'new Thread($$).start()' || echo 0) + $("${GREP_RN[@]}" -e "new[[:space:]]+Thread\s*\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$thr_start" -gt 0 ]; then print_finding "info" "$thr_start" "Manual thread creation detected"; fi

print_subheader "Executors.newCachedThreadPool (unbounded)"
cached_pool=$(( $(ast_search 'java.util.concurrent.Executors.newCachedThreadPool($$)' || echo 0) + $("${GREP_RN[@]}" -e "Executors\.newCachedThreadPool\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$cached_pool" -gt 0 ]; then print_finding "warning" "$cached_pool" "newCachedThreadPool unbounded threads"; fi

print_subheader "Thread.sleep in synchronized blocks"
sleep_sync=$(( $(ast_search 'synchronized($L) { $$ java.lang.Thread.sleep($D); $$ }' || echo 0) + $("${GREP_RN[@]}" -e "synchronized\s*\([^\)]+\)\s*\{[^}]*Thread\.sleep\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$sleep_sync" -gt 0 ]; then print_finding "info" "$sleep_sync" "Thread.sleep within synchronized block"; fi

print_subheader "notify() usage"
notify_count=$(( $(ast_search '$O.notify()' || echo 0) + $("${GREP_RN[@]}" -e "\.notify\(\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$notify_count" -gt 0 ]; then print_finding "info" "$notify_count" "notify() calls detected - ensure correct semantics"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 4: SECURITY
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 4; then
print_header "4. SECURITY"
print_category "Detects: Insecure SSL, weak hashes, http://, insecure deserialization, Random for secrets" \
  "Security misconfigurations expose users to attacks and data breaches"

print_subheader "SSL verification disabled (CRITICAL)"
ssl_insecure=$(( $(ast_search 'javax.net.ssl.HttpsURLConnection.setDefaultHostnameVerifier(($H, $S) -> true)' || echo 0) + $(ast_search 'new javax.net.ssl.X509TrustManager { $$ }' || echo 0) + $("${GREP_RN[@]}" -e "HostnameVerifier\W*\(\W*.*->\W*true\W*\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$ssl_insecure" -gt 0 ]; then print_finding "critical" "$ssl_insecure" "SSL/TLS validation disabled"; fi

print_subheader "Weak hash algorithms (MD5/SHA-1)"
weak_hash=$(( $(ast_search 'java.security.MessageDigest.getInstance("MD5")' || echo 0) + $(ast_search 'java.security.MessageDigest.getInstance("SHA-1")' || echo 0) + $("${GREP_RN[@]}" -e "MessageDigest\.getInstance\(\"(MD5|SHA-1)\"\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$weak_hash" -gt 0 ]; then print_finding "warning" "$weak_hash" "Weak hash detected - prefer SHA-256/512"; fi

print_subheader "Plain HTTP URLs"
http_url=$(( $(ast_search '"http://$REST"' || echo 0) + $("${GREP_RN[@]}" -e "http://[A-Za-z0-9]" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$http_url" -gt 0 ]; then print_finding "info" "$http_url" "Plain HTTP URL(s) present"; fi

print_subheader "Java deserialization"
deser=$(( $(ast_search 'new java.io.ObjectInputStream($$).readObject()' || echo 0) + $("${GREP_RN[@]}" -e "ObjectInputStream\(.+\)\.readObject\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$deser" -gt 0 ]; then print_finding "warning" "$deser" "Object deserialization detected"; fi

print_subheader "java.util.Random usage"
rand=$(( $(ast_search 'new java.util.Random($$)' || echo 0) + $("${GREP_RN[@]}" -e "new[[:space:]]+Random\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$rand" -gt 0 ]; then print_finding "info" "$rand" "Random used; prefer SecureRandom for secrets"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 5: I/O & RESOURCES
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 5; then
print_header "5. I/O & RESOURCES"
print_category "Detects: missing charset, blocking reads in loops, delete() unchecked" \
  "I/O patterns that cause correctness or performance issues"

print_subheader "InputStreamReader without charset"
isr=$(( $(ast_search 'new java.io.InputStreamReader($S)' || echo 0) + $("${GREP_RN[@]}" -e "new[[:space:]]+InputStreamReader\([^)]+\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$isr" -gt 0 ]; then print_finding "info" "$isr" "InputStreamReader without charset"; fi

print_subheader "new String(bytes) without charset or getBytes() without charset"
str_bytes=$(( $(ast_search 'new String($B)' || echo 0) + $(ast_search '$S.getBytes()' || echo 0) + $("${GREP_RN[@]}" -e "new[[:space:]]+String\(\s*[A-Za-z0-9_]+\s*\)|\.getBytes\(\s*\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$str_bytes" -gt 0 ]; then print_finding "info" "$str_bytes" "Charset not specified in String/bytes conversion"; fi

print_subheader "Files.readAllBytes / large reads inside loops"
read_all_bytes_loop=$("${GREP_RN[@]}" -e "for[[:space:]]*\(|while[[:space:]]*\(" "$PROJECT_DIR" 2>/dev/null | (grep -A4 "Files\.readAllBytes\(" || true) | (grep -c "Files\.readAllBytes\(" || true))
read_all_bytes_loop=$(echo "$read_all_bytes_loop" | awk 'END{print $0+0}')
if [ "$read_all_bytes_loop" -gt 0 ]; then print_finding "warning" "$read_all_bytes_loop" "Files.readAllBytes in loop - consider streaming"; fi

print_subheader "File.delete() without result check"
del_unchecked=$("${GREP_RN[@]}" -e "\.delete\(\)\s*;" "$PROJECT_DIR" 2>/dev/null | (grep -vE "if\s*\(|assert|check|ensure" || true) | count_lines)
if [ "$del_unchecked" -gt 0 ]; then print_finding "info" "$del_unchecked" "File.delete() return value not checked"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 6: LOGGING & DEBUGGING
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 6; then
print_header "6. LOGGING & DEBUGGING"
print_category "Detects: System.out/err.println, printStackTrace, TODO/FIXME/HACK markers" \
  "Debug code left in production affects performance and leaks info"

print_subheader "System.out/err.println"
println_cnt=$(( $(ast_search 'System.out.println($$)' || echo 0) + $(ast_search 'System.err.println($$)' || echo 0) + $("${GREP_RN[@]}" -e "System\.(out|err)\.println\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$println_cnt" -gt 0 ]; then print_finding "info" "$println_cnt" "System.out/err.println present - prefer logger"; fi

print_subheader "printStackTrace calls"
pst_cnt=$(( $(ast_search '$E.printStackTrace()' || echo 0) + $("${GREP_RN[@]}" -e "\.printStackTrace\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$pst_cnt" -gt 0 ]; then print_finding "warning" "$pst_cnt" "printStackTrace leaks details"; fi

print_subheader "Technical debt markers"
todo_count=$("${GREP_RNI[@]}" "TODO" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
fixme_count=$("${GREP_RNI[@]}" "FIXME" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
hack_count=$("${GREP_RNI[@]}" "HACK" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
note_count=$("${GREP_RNI[@]}" "NOTE" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
total_markers=$((todo_count + fixme_count + hack_count))
if [ "$total_markers" -gt 20 ]; then
  print_finding "warning" "$total_markers" "Significant technical debt"
elif [ "$total_markers" -gt 0 ]; then
  print_finding "info" "$total_markers" "TODO/FIXME/HACK markers present"
else
  print_finding "good" "No technical debt markers"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 7: REGEX & STRING PITFALLS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 7; then
print_header "7. REGEX & STRING PITFALLS"
print_category "Detects: ReDoS patterns, Pattern.compile with variables, toLowerCase/equals" \
  "String/regex bugs cause performance issues and subtle mismatches"

print_subheader "Nested quantifiers (ReDoS risk)"
redos_cnt=$("${GREP_RN[@]}" -e "\([^)]*\+[^)]*\)\+|\([^)]*\*[^)]*\)\+" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$redos_cnt" -gt 0 ]; then print_finding "warning" "$redos_cnt" "Regex contains nested quantifiers - potential ReDoS"; show_detailed_finding "\([^)]*\+[^)]*\)\+|\([^)]*\*[^)]*\)\+" 3; fi

print_subheader "Pattern.compile with variables (injection risk)"
dyn_pat=$("${GREP_RN[@]}" -e "Pattern\.compile\(\s*[A-Za-z_][A-Za-z0-9_]*\s*\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$dyn_pat" -gt 0 ]; then print_finding "info" "$dyn_pat" "Dynamic Pattern.compile detected - sanitize/escape user input"; fi

print_subheader "Case handling via toLowerCase()/toUpperCase() then equals"
case_cmp=$("${GREP_RN[@]}" -e "\.to(Lower|Upper)Case\(\)\.equals\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$case_cmp" -gt 0 ]; then print_finding "info" "$case_cmp" "Prefer equalsIgnoreCase or use Locale"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 8: COLLECTIONS & GENERICS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 8; then
print_header "8. COLLECTIONS & GENERICS"
print_category "Detects: raw types, legacy Vector/Hashtable, remove in foreach" \
  "Raw types and mutation during iteration cause runtime errors"

print_subheader "Raw generic types (List/Map/Set without <...>)"
raw_types=$("${GREP_RN[@]}" -e "\b(List|Map|Set)\s+[a-zA-Z_][a-zA-Z0-9_]*\s*(=|;)" "$PROJECT_DIR" 2>/dev/null | (grep -v '<' || true) | count_lines)
if [ "$raw_types" -gt 0 ]; then print_finding "warning" "$raw_types" "Raw generic types used"; fi

print_subheader "Legacy synchronized collections"
legacy=$(( $(ast_search 'new java.util.Vector($$)' || echo 0) + $(ast_search 'new java.util.Hashtable($$)' || echo 0) + $("${GREP_RN[@]}" -e "new[[:space:]]+(Vector|Hashtable)\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$legacy" -gt 0 ]; then print_finding "info" "$legacy" "Vector/Hashtable detected"; fi

print_subheader "Collection modification during foreach (heuristic)"
mod_foreach=$("${GREP_RN[@]}" -e "for\s*\([^)]+:[^)]+\)\s*\{" "$PROJECT_DIR" 2>/dev/null | (grep -A3 "\.remove\(" || true) | (grep -c "\.remove\(" || true))
mod_foreach=$(echo "$mod_foreach" | awk 'END{print $0+0}')
if [ "$mod_foreach" -gt 0 ]; then print_finding "warning" "$mod_foreach" "Possible modification of collection during iteration"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 9: SWITCH & CONTROL FLOW
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 9; then
print_header "9. SWITCH & CONTROL FLOW"
print_category "Detects: fall-through (classic switch), switch without default" \
  "Control flow bugs cause unexpected behavior"

print_subheader "Classic switch fall-through (ignore '->' labels)"
switch_count=$("${GREP_RN[@]}" -e "switch\s*\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
case_count=$("${GREP_RN[@]}" -e "case[[:space:]]+.*:" "$PROJECT_DIR" 2>/dev/null | (grep -v "->" || true) | count_lines || true)
break_count=$("${GREP_RN[@]}" -e "\bbreak\s*;" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$case_count" -gt "$break_count" ] && [ "$case_count" -gt 0 ]; then
  diff=$((case_count - break_count))
  print_finding "warning" "$diff" "Switch cases may be missing break (classic switch)"
fi

print_subheader "Switch without default (classic switch)"
default_count=$("${GREP_RN[@]}" -e "default[[:space:]]*:" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$switch_count" -gt "$default_count" ] && [ "$switch_count" -gt 0 ]; then
  diff=$((switch_count - default_count))
  print_finding "info" "$diff" "Some switch statements have no default case (classic syntax)"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 10: STREAMS & PERFORMANCE
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 10; then
print_header "10. STREAMS & PERFORMANCE"
print_category "Detects: parallel().forEach, String concatenation in loops" \
  "Performance pitfalls that scale poorly"

print_subheader "parallel().forEach side-effect risk"
par_for_each=$(( $(ast_search '$SRC.parallel().forEach($$)' || echo 0) + $("${GREP_RN[@]}" -e "\.parallel\(\)\.forEach\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$par_for_each" -gt 0 ]; then print_finding "info" "$par_for_each" "parallel forEach detected - ensure thread-safe side effects"; fi

print_subheader "String concatenation in loops"
str_plus_loop=$("${GREP_RN[@]}" -e "for\s*\(|while\s*\(" "$PROJECT_DIR" 2>/dev/null | (grep -A3 "\+=\"" || true) | (grep -cw "\+=\"" || true))
str_plus_loop=$(echo "$str_plus_loop" | awk 'END{print $0+0}')
if [ "$str_plus_loop" -gt 0 ]; then print_finding "info" "$str_plus_loop" "String '+=' in loops - prefer StringBuilder"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 11: SERIALIZATION & COMPATIBILITY
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 11; then
print_header "11. SERIALIZATION & COMPATIBILITY"
print_category "Detects: implements Serializable, readObject/writeObject" \
  "Serialization hazards and maintenance burdens"

print_subheader "Serializable implementations (inventory)"
serializable=$("${GREP_RN[@]}" -e "implements\s+Serializable\b" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$serializable" -gt 0 ]; then print_finding "info" "$serializable" "Classes implement Serializable - audit necessity"; fi

print_subheader "Custom readObject/writeObject methods"
custom_ser=$("${GREP_RN[@]}" -e "void\s+readObject\s*\(|void\s+writeObject\s*\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$custom_ser" -gt 0 ]; then print_finding "info" "$custom_ser" "Custom serialization hooks present - validate invariants"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 12: JAVA 21 FEATURES (INFO)
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 12; then
print_header "12. JAVA 21 FEATURES (INFO)"
print_category "Detects: Virtual Threads, Structured Concurrency, Sequenced Collections" \
  "Inventory of modern APIs to guide reviews for correct usage"

print_subheader "Virtual Threads"
virt_threads=$(( $(ast_search 'java.lang.Thread.ofVirtual().start($$)' || echo 0) + $("${GREP_RN[@]}" -e "Thread\.ofVirtual\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true) ))
if [ "$virt_threads" -gt 0 ]; then print_finding "info" "$virt_threads" "Virtual threads in use - ensure blocking operations are appropriate"; fi

print_subheader "StructuredTaskScope"
scope_cnt=$("${GREP_RN[@]}" -e "StructuredTaskScope" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$scope_cnt" -gt 0 ]; then print_finding "info" "$scope_cnt" "StructuredTaskScope in use - validate proper join/shutdown handling"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 13: SQL CONSTRUCTION (HEURISTICS)
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 13; then
print_header "13. SQL CONSTRUCTION (HEURISTICS)"
print_category "Detects: string-concatenated SQL, Statement.executeQuery with + operator" \
  "Prefer prepared statements with parameters to avoid injection"

print_subheader "String-concatenated SQL"
sql_concat=$("${GREP_RN[@]}" -e "\"(SELECT|INSERT|UPDATE|DELETE)[^\"]*\"[[:space:]]*\\+[[:space:]]*[A-Za-z0-9_]" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$sql_concat" -gt 0 ]; then print_finding "warning" "$sql_concat" "SQL built via concatenation - prefer parameters"; fi

print_subheader "Statement.executeQuery with concatenation"
exec_concat=$("${GREP_RN[@]}" -e "execute(Query|Update)\s*\(" "$PROJECT_DIR" 2>/dev/null | (grep "\+" || true) | count_lines)
if [ "$exec_concat" -gt 0 ]; then print_finding "warning" "$exec_concat" "execute* called with concatenated query string"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 14: ANNOTATIONS & NULLNESS (HEURISTICS)
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 14; then
print_header "14. ANNOTATIONS & NULLNESS (HEURISTICS)"
print_category "Detects: @Nullable without guard (approx), @Deprecated usages" \
  "Annotation-driven contracts must be respected"

print_subheader "@Nullable parameters used without null guard (approx)"
nullable_params=$("${GREP_RN[@]}" -e "@Nullable" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$nullable_params" -gt 0 ]; then print_finding "info" "$nullable_params" "@Nullable present - ensure null checks at use sites"; fi

print_subheader "Usage of @Deprecated APIs"
deprecated_use=$("${GREP_RN[@]}" -e "@Deprecated|@deprecated" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$deprecated_use" -gt 0 ]; then print_finding "info" "$deprecated_use" "Deprecated annotations present - verify migration plans"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 15: AST-GREP RULE PACK FINDINGS (JSON/SARIF passthrough)
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 15; then
print_header "15. AST-GREP RULE PACK FINDINGS"
if [[ "$HAS_AST_GREP" -eq 1 && -n "$AST_RULE_DIR" ]]; then
  run_ast_rules || true
  say "${DIM}${INFO} Above JSON/SARIF lines are ast-grep matches (id, message, severity, file/pos).${RESET}"
  if [[ "$FORMAT" == "sarif" ]]; then
    say "${DIM}${INFO} Tip: ${BOLD}${AST_GREP_CMD[*]} scan -r $AST_RULE_DIR \"$PROJECT_DIR\" --sarif > report.sarif${RESET}"
  fi
else
  say "${YELLOW}${WARN} ast-grep scan subcommand unavailable; rule-pack mode skipped.${RESET}"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 16: BUILD HEALTH (Maven/Gradle best-effort)
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 16; then
print_header "16. BUILD HEALTH (Maven/Gradle)"
print_category "Runs: compile/test-compile tasks; optional lint tasks if configured" \
  "Ensures the project compiles; inventories warnings/errors"

if [[ "$RUN_BUILD" -eq 1 ]]; then
  # Maven compile
  if [[ "$HAS_MAVEN" -eq 1 && -f "$PROJECT_DIR/pom.xml" ]]; then
    MVN_BIN="${MVNW:-mvn}"
    MVN_LOG="$(mktemp)"
    run_cmd_log "$MVN_LOG" bash -lc "cd \"$PROJECT_DIR\" && \"$MVN_BIN\" -q -e -T1C -DskipTests=true -DskipITs=true -Dmaven.test.skip.exec=true -Dspotbugs.skip=true -Dpmd.skip=true -Dcheckstyle.skip=true -Denforcer.skip=true -Dgpg.skip=true -Dlicense.skip=true -Drat.skip=true -Djacoco.skip=true -Danimal.sniffer.skip=true -Dskip.npm -Dskip.yarn -Dskip.node -DskipFrontend -Dfrontend.skip=true -U -B compile"
    mvn_ec=$(cat "$MVN_LOG.ec" 2>/dev/null || echo 0)
    w_e=$(count_warnings_errors_text "$MVN_LOG"); w=$(echo "$w_e" | awk '{print $1}'); e=$(echo "$w_e" | awk '{print $2}')
    if [[ "$mvn_ec" -ne 0 || "$e" -gt 0 ]]; then print_finding "critical" "$e" "Maven compile errors detected"; else print_finding "good" "Maven compile OK"; fi
    if [[ "$w" -gt 0 ]]; then print_finding "warning" "$w" "Maven compile warnings"; fi
  fi

  # Gradle compile
  if [[ "$HAS_GRADLE" -eq 1 && ( -f "$PROJECT_DIR/build.gradle" || -f "$PROJECT_DIR/build.gradle.kts" ) ]]; then
    GR_BIN="${GRADLEW:-gradle}"
    GR_TASKS="$(mktemp)"
    run_cmd_log "$GR_TASKS" bash -lc "cd \"$PROJECT_DIR\" && \"$GR_BIN\" --no-daemon -q tasks --all"
    GR_LOG="$(mktemp)"
    run_cmd_log "$GR_LOG" bash -lc "cd \"$PROJECT_DIR\" && \"$GR_BIN\" --no-daemon -q classes testClasses -x test"
    gr_ec=$(cat "$GR_LOG.ec" 2>/dev/null || echo 0)
    w_e=$(count_warnings_errors_text "$GR_LOG"); w=$(echo "$w_e" | awk '{print $1}'); e=$(echo "$w_e" | awk '{print $2}')
    if [[ "$gr_ec" -ne 0 || "$e" -gt 0 ]]; then print_finding "critical" "$e" "Gradle compile errors detected"; else print_finding "good" "Gradle compile OK"; fi
    if [[ "$w" -gt 0 ]]; then print_finding "warning" "$w" "Gradle compile warnings"; fi

    # Try optional lint tasks if they exist
    if grep -q "checkstyleMain" "$GR_TASKS"; then
      CS_LOG="$(mktemp)"; run_cmd_log "$CS_LOG" bash -lc "cd \"$PROJECT_DIR\" && \"$GR_BIN\" --no-daemon -q checkstyleMain -x test"
      w_e=$(count_warnings_errors_text "$CS_LOG"); w=$(echo "$w_e" | awk '{print $1}'); e=$(echo "$w_e" | awk '{print $2}')
      if [[ "$e" -gt 0 ]]; then print_finding "warning" "$e" "Checkstyle issues (Gradle)"; fi
    fi
    if grep -q "pmdMain" "$GR_TASKS"; then
      PMD_LOG="$(mktemp)"; run_cmd_log "$PMD_LOG" bash -lc "cd \"$PROJECT_DIR\" && \"$GR_BIN\" --no-daemon -q pmdMain -x test"
      w_e=$(count_warnings_errors_text "$PMD_LOG"); w=$(echo "$w_e" | awk '{print $1}'); e=$(echo "$w_e" | awk '{print $2}')
      if [[ "$e" -gt 0 || "$w" -gt 0 ]]; then print_finding "warning" "$((w+e))" "PMD issues (Gradle)"; fi
    fi
    if grep -q "spotbugsMain" "$GR_TASKS"; then
      SB_LOG="$(mktemp)"; run_cmd_log "$SB_LOG" bash -lc "cd \"$PROJECT_DIR\" && \"$GR_BIN\" --no-daemon -q spotbugsMain -x test"
      if grep -qi "bug" "$SB_LOG"; then
        sb_cnt=$(grep -i "bug" "$SB_LOG" | wc -l | awk '{print $1+0}')
        print_finding "warning" "$sb_cnt" "SpotBugs reported potential issues"
      fi
    fi
  fi
else
  print_finding "info" 1 "Build checks disabled (--no-build)"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 17: META STATISTICS & INVENTORY
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 17; then
print_header "17. META STATISTICS & INVENTORY"
print_category "Detects: project type (Maven/Gradle), Java version" \
  "High-level overview of the project"

proj_type="Unknown"
if [[ -f "$PROJECT_DIR/pom.xml" ]]; then proj_type="Maven"; fi
if [[ -f "$PROJECT_DIR/build.gradle" || -f "$PROJECT_DIR/build.gradle.kts" ]]; then proj_type="Gradle"; fi
say "  ${BLUE}${INFO} Info${RESET} ${WHITE}(project:${RESET} ${CYAN}${proj_type}${RESET}${WHITE}, java:${RESET} ${CYAN}${JAVA_VERSION_STR:-unknown}${RESET}${WHITE})${RESET}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 18: MISC API MISUSE
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 18; then
print_header "18. MISC API MISUSE"
print_category "Detects: System.runFinalizersOnExit, Thread.stop, setAccessible(true)" \
  "Legacy and unsafe APIs"

print_subheader "Legacy/unsafe API calls"
finalizers=$("${GREP_RN[@]}" -e "System\.runFinalizersOnExit\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
thread_stop=$("${GREP_RN[@]}" -e "Thread\.stop\(|Thread\.suspend\(|Thread\.resume\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
set_access=$("${GREP_RN[@]}" -e "\.setAccessible\(\s*true\s*\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$finalizers" -gt 0 ]; then print_finding "critical" "$finalizers" "System.runFinalizersOnExit used - do not use"; fi
if [ "$thread_stop" -gt 0 ]; then print_finding "critical" "$thread_stop" "Thread.stop/suspend/resume used - unsafe"; fi
if [ "$set_access" -gt 0 ]; then print_finding "info" "$set_access" "setAccessible(true) used - restrict usage"; fi
fi

# restore pipefail
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

say "${BOLD}${WHITE}Priority Actions:${RESET}"
if [ "$CRITICAL_COUNT" -gt 0 ]; then
  say "  ${RED}${FIRE} ${BOLD}FIX CRITICAL ISSUES IMMEDIATELY${RESET}"
  say "  ${DIM}These cause crashes, security vulnerabilities, or data corruption${RESET}"
fi
if [ "$WARNING_COUNT" -gt 0 ]; then
  say "  ${YELLOW}${WARN} ${BOLD}Review and fix WARNING items${RESET}"
  say "  ${DIM}These cause bugs, performance issues, or maintenance problems${RESET}"
fi
if [ "$INFO_COUNT" -gt 0 ]; then
  say "  ${BLUE}${INFO} ${BOLD}Consider INFO suggestions${RESET}"
  say "  ${DIM}Code quality improvements and best practices${RESET}"
fi

if [ "$CRITICAL_COUNT" -eq 0 ] && [ "$WARNING_COUNT" -eq 0 ]; then
  say "\n  ${GREEN}${BOLD}${SPARKLE} EXCELLENT! No critical or warning issues found ${SPARKLE}${RESET}"
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
say "${DIM}Add to CI: ./ubs --ci --fail-on-warning . > java-bug-scan.txt${RESET}"
echo ""

EXIT_CODE=0
if [ "$CRITICAL_COUNT" -gt 0 ]; then EXIT_CODE=1; fi
if [ "$FAIL_ON_WARNING" -eq 1 ] && [ $((CRITICAL_COUNT + WARNING_COUNT)) -gt 0 ]; then EXIT_CODE=1; fi
exit "$EXIT_CODE"
