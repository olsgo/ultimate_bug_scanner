#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# RUBY ULTIMATE BUG SCANNER v1.0 (Bash) - Industrial-Grade Code Analysis
# ═══════════════════════════════════════════════════════════════════════════
# Comprehensive static analysis for modern Ruby (3.3+) using:
#   • ast-grep (rule packs; language: ruby)
#   • ripgrep/grep heuristics for fast code smells
#   • optional Bundler-powered extra analyzers:
#       - rubocop (lint/style), brakeman (Rails security),
#         bundler-audit (dependency vulns), reek (code smells), fasterer (perf)
#
# Focus:
#   • nil & defensive checks     • exceptions & error handling
#   • shell/subprocess safety     • security & crypto hygiene
#   • I/O & resource handling     • typing/idioms & metaprogramming risks
#   • regex safety (ReDoS)        • code quality markers & performance
#
# Supports:
#   --format text|json|sarif (ast-grep passthrough for json/sarif)
#   --rules DIR   (merge user ast-grep rules)
#   --fail-on-warning, --skip, --jobs, --include-ext, --exclude, --ci, --no-color
#   CI-friendly timestamps, robust find, safe pipelines, auto parallel jobs
# ═══════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail
shopt -s lastpipe
shopt -s extglob

on_err() {
  local ec=$?; local cmd=${BASH_COMMAND}; local line=${BASH_LINENO[0]}; local src=${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}
  echo -e "\n${RED}${BOLD}Unexpected error (exit $ec)${RESET} ${DIM}at ${src}:${line}${RESET}\n${DIM}Last command:${RESET} ${WHITE}$cmd${RESET}" >&2
  exit "$ec"
}
trap on_err ERR

# Honor NO_COLOR and non-tty
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

CHECK="✓"; CROSS="✗"; WARN="⚠"; INFO="ℹ"; ARROW="→"; BULLET="•"; MAGNIFY="🔍"; BUG="🐛"; FIRE="🔥"; SPARKLE="✨"; SHIELD="🛡"; GEM="💎"

# ────────────────────────────────────────────────────────────────────────────
# CLI Parsing & Configuration
# ────────────────────────────────────────────────────────────────────────────
VERBOSE=0
PROJECT_DIR="."
OUTPUT_FILE=""
FORMAT="text"          # text|json|sarif (text implemented; ast-grep emits json/sarif when rule packs are run)
CI_MODE=0
FAIL_ON_WARNING=0
INCLUDE_EXT="rb,rake,ru,gemspec,erb,haml,slim"
QUIET=0
NO_COLOR_FLAG=0
EXTRA_EXCLUDES=""
SKIP_CATEGORIES=""
DETAIL_LIMIT=3
MAX_DETAILED=250
JOBS="${JOBS:-0}"
USER_RULE_DIR=""
DISABLE_PIPEFAIL_DURING_SCAN=1

ENABLE_BUNDLER_TOOLS=1
RB_TOOLS="rubocop,brakeman,bundler-audit,reek,fasterer"
RB_TIMEOUT="${RB_TIMEOUT:-1200}"

print_usage() {
  cat >&2 <<USAGE
Usage: $(basename "$0") [options] [PROJECT_DIR] [OUTPUT_FILE]

Options:
  -v, --verbose            More code samples per finding (DETAIL=10)
  -q, --quiet              Reduce non-essential output
  --format=FMT             Output format: text|json|sarif (default: text)
  --ci                     CI mode (no clear, stable timestamps)
  --no-color               Force disable ANSI color
  --include-ext=CSV        File extensions (default: $INCLUDE_EXT)
  --exclude=GLOB[,..]      Additional glob(s)/dir(s) to exclude
  --jobs=N                 Parallel jobs for ripgrep (default: auto)
  --skip=CSV               Skip categories by number (e.g. --skip=2,7,11)
  --fail-on-warning        Exit non-zero on warnings or critical
  --rules=DIR              Additional ast-grep rules directory (merged)
  --no-bundler             Disable bundler-based extra analyzers
  --rb-tools=CSV           Which extra tools to run (default: $RB_TOOLS)
  -h, --help               Show help
Env:
  JOBS, NO_COLOR, CI, RB_TIMEOUT
Args:
  PROJECT_DIR              Directory to scan (default: ".")
  OUTPUT_FILE              File to save the report (optional)
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
    --no-bundler) ENABLE_BUNDLER_TOOLS=0; shift;;
    --rb-tools=*) RB_TOOLS="${1#*=}"; shift;;
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

# CI auto-detect + color override
if [[ -n "${CI:-}" ]]; then CI_MODE=1; fi
if [[ "$NO_COLOR_FLAG" -eq 1 ]]; then USE_COLOR=0; fi

# Redirect output early to capture everything
if [[ -n "${OUTPUT_FILE}" ]]; then exec > >(tee "${OUTPUT_FILE}") 2>&1; fi

DATE_FMT='%Y-%m-%d %H:%M:%S'
if [[ "$CI_MODE" -eq 1 ]]; then DATE_CMD="date -u '+%Y-%m-%dT%H:%M:%SZ'"; else DATE_CMD="date '+$DATE_FMT'"; fi

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
HAS_AST_GREP=0
AST_GREP_CMD=()
AST_RULE_DIR=""
HAS_RIPGREP=0
HAS_BUNDLE=0
BUNDLE_EXEC=()

# ────────────────────────────────────────────────────────────────────────────
# Search engine configuration (rg if available, else grep) + include/exclude
# ────────────────────────────────────────────────────────────────────────────
LC_ALL=C
IFS=',' read -r -a _EXT_ARR <<<"$INCLUDE_EXT"
INCLUDE_GLOBS=()
for e in "${_EXT_ARR[@]}"; do INCLUDE_GLOBS+=( "--include=*.$(echo "$e" | xargs)" ); done

EXCLUDE_DIRS=(.git .hg .svn .bzr .bundle vendor/bundle vendor/cache log tmp .yardoc coverage .tox .nox .cache .idea .vscode .history node_modules dist build pkg doc public/assets storage .sass-cache .rubocop-cache .reek .bundle-audit .solargraph .yardoc .gem)
if [[ -n "$EXTRA_EXCLUDES" ]]; then IFS=',' read -r -a _X <<<"$EXTRA_EXCLUDES"; EXCLUDE_DIRS+=("${_X[@]}"); fi
EXCLUDE_FLAGS=()
for d in "${EXCLUDE_DIRS[@]}"; do EXCLUDE_FLAGS+=( "--exclude-dir=$d" ); done

if command -v rg >/dev/null 2>&1; then
  HAS_RIPGREP=1
  if [[ "${JOBS}" -eq 0 ]]; then JOBS="$( (command -v nproc >/dev/null && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 0 )"; fi
  RG_JOBS=(); if [[ "${JOBS}" -gt 0 ]]; then RG_JOBS=(-j "$JOBS"); fi
  RG_BASE=(--no-config --no-messages --line-number --with-filename --hidden --pcre2 "${RG_JOBS[@]}")
  RG_EXCLUDES=()
  for d in "${EXCLUDE_DIRS[@]}"; do RG_EXCLUDES+=( -g "!$d/**" ); done
  RG_INCLUDES=()
  for e in "${_EXT_ARR[@]}"; do RG_INCLUDES+=( -g "*.$(echo "$e" | xargs)" ); done
  GREP_RN=(rg "${RG_BASE[@]}" "${RG_EXCLUDES[@]}" "${RG_INCLUDES[@]}")
  GREP_RNI=(rg -i "${RG_BASE[@]}" "${RG_EXCLUDES[@]}" "${RG_INCLUDES[@]}")
  GREP_RNW=(rg -w "${RG_BASE[@]}" "${RG_EXCLUDES[@]}" "${RG_INCLUDES[@]}")
  RG_JOBS=()
else
  GREP_R_OPTS=(-R --binary-files=without-match "${EXCLUDE_FLAGS[@]}" "${INCLUDE_GLOBS[@]}")
  GREP_RN=("grep" "${GREP_R_OPTS[@]}" -n -E)
  GREP_RNI=("grep" "${GREP_R_OPTS[@]}" -n -i -E)
  GREP_RNW=("grep" "${GREP_R_OPTS[@]}" -n -w -E)
fi

# Helper: robust numeric end-of-pipeline counter
count_lines() { awk 'END{print (NR+0)}'; }

# ────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ────────────────────────────────────────────────────────────────────────────
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

show_ast_samples_from_json() {
  local blob=$1
  [[ -n "$blob" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then return 0; fi
  jq -cr '.samples[]?' <<<"$blob" | while IFS= read -r sample; do
    local file line code
    file=$(printf '%s' "$sample" | jq -r '.file')
    line=$(printf '%s' "$sample" | jq -r '.line')
    code=$(printf '%s' "$sample" | jq -r '.code')
    print_code_sample "$file" "$line" "$code"
  done
}

persist_metric_json() {
  local key=$1; local payload=$2
  [[ -n "$key" && -n "$payload" ]] || return 0
  [[ -n "${UBS_METRICS_DIR:-}" ]] || return 0
  mkdir -p "$UBS_METRICS_DIR" 2>/dev/null || true
  {
    printf '{"%s":' "$key"
    printf '%s' "$payload"
    printf '}'
  } >"$UBS_METRICS_DIR/$key.json"
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

with_timeout() {
  # with_timeout <seconds> <command...>
  local seconds="$1"; shift || true
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# ast-grep: detection, rule packs, and wrappers
# ────────────────────────────────────────────────────────────────────────────
check_ast_grep() {
  if command -v ast-grep >/dev/null 2>&1; then AST_GREP_CMD=(ast-grep); HAS_AST_GREP=1; return 0; fi
  if command -v sg       >/dev/null 2>&1; then AST_GREP_CMD=(sg);       HAS_AST_GREP=1; return 0; fi
  if command -v npx      >/dev/null 2>&1; then AST_GREP_CMD=(npx -y @ast-grep/cli); HAS_AST_GREP=1; return 0; fi
  say "${YELLOW}${WARN} ast-grep not found. Advanced AST checks will be skipped.${RESET}"
  say "${DIM}Tip: npm i -g @ast-grep/cli  or  cargo install ast-grep${RESET}"
  HAS_AST_GREP=0; return 1
}

ast_search() {
  local pattern=$1
  if [[ "$HAS_AST_GREP" -eq 1 ]]; then
    ( set +o pipefail; "${AST_GREP_CMD[@]}" --pattern "$pattern" --lang ruby "$PROJECT_DIR" 2>/dev/null || true ) | wc -l | awk '{print $1+0}'
  else
    return 1
  fi
}

analyze_rb_chain_guards() {
  local limit=${1:-$DETAIL_LIMIT}
  if [[ "$HAS_AST_GREP" -ne 1 ]]; then return 1; fi
  if ! command -v python3 >/dev/null 2>&1; then return 1; fi
  local tmp_chains tmp_ifs result
  tmp_chains="$(mktemp -t ubs-rb-chains.XXXXXX 2>/dev/null || mktemp -t ubs-rb-chains)"
  tmp_ifs="$(mktemp -t ubs-rb-ifs.XXXXXX 2>/dev/null || mktemp -t ubs-rb-ifs)"

  ( set +o pipefail; "${AST_GREP_CMD[@]}" --pattern '$OBJ.$P1.$P2.$P3' --lang ruby "$PROJECT_DIR" --json=stream 2>/dev/null || true ) >"$tmp_chains"
  ( set +o pipefail; "${AST_GREP_CMD[@]}" --pattern $'if $COND\n  $BODY\nend' --lang ruby "$PROJECT_DIR" --json=stream 2>/dev/null || true ) >"$tmp_ifs"

  result=$(python3 - "$tmp_chains" "$tmp_ifs" "$limit" <<'PYHELP'
import json, sys
from collections import defaultdict

def load_stream(path):
    data = []
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    data.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        return data
    return data

matches_path, guards_path, limit_raw = sys.argv[1:4]
limit = int(limit_raw)
matches = load_stream(matches_path)
guards = load_stream(guards_path)

def as_pos(node):
    return (node.get('line', 0), node.get('column', 0))

def ge(a, b):
    return a[0] > b[0] or (a[0] == b[0] and a[1] >= b[1])

def le(a, b):
    return a[0] < b[0] or (a[0] == b[0] and a[1] <= b[1])

def within(target, region):
    start, end = target
    rs, re = region
    return ge(start, rs) and le(end, re)

guards_by_file = defaultdict(list)
for guard in guards:
    file_path = guard.get('file')
    cond = guard.get('metaVariables', {}).get('single', {}).get('COND')
    if not file_path or not cond:
        continue
    rng = cond.get('range') or {}
    start = rng.get('start'); end = rng.get('end')
    if not start or not end:
        continue
    guards_by_file[file_path].append((as_pos(start), as_pos(end)))

unguarded = 0
guarded = 0
samples = []

for match in matches:
    file_path = match.get('file')
    rng = match.get('range') or {}
    start = rng.get('start'); end = rng.get('end')
    if not file_path or not start or not end:
        continue
    start_pos = as_pos(start); end_pos = as_pos(end)
    regions = guards_by_file.get(file_path, [])
    if any(within((start_pos, end_pos), region) for region in regions):
        guarded += 1
        continue
    unguarded += 1
    if len(samples) < limit:
        snippet = (match.get('lines') or '').strip()
        samples.append({'file': file_path, 'line': start_pos[0] + 1, 'code': snippet})

print(json.dumps({'unguarded': unguarded, 'guarded': guarded, 'samples': samples}, ensure_ascii=False))
PYHELP
  )

  rm -f "$tmp_chains" "$tmp_ifs"
  printf '%s' "$result"
}

write_ast_rules() {
  [[ "$HAS_AST_GREP" -eq 1 ]] || return 0
  AST_RULE_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t rb_ag_rules.XXXXXX)"
  trap '[[ -n "${AST_RULE_DIR:-}" ]] && rm -rf "$AST_RULE_DIR" || true' EXIT
  if [[ -n "$USER_RULE_DIR" && -d "$USER_RULE_DIR" ]]; then
    cp -R "$USER_RULE_DIR"/. "$AST_RULE_DIR"/ 2>/dev/null || true
  fi

  # ── Core Ruby rules ───────────────────────────────────────────────────────
  cat >"$AST_RULE_DIR/nil-eq.yml" <<'YAML'
id: rb.nil-eq
language: ruby
rule:
  any:
    - pattern: $X == nil
    - pattern: $X != nil
severity: warning
message: "Prefer x.nil? / !x.nil? instead of == nil / != nil"
YAML

  cat >"$AST_RULE_DIR/is-literal.yml" <<'YAML'
id: rb.equal-literal
language: ruby
rule:
  any:
    - pattern: $X.equal?(true)
    - pattern: $X.equal?(false)
    - pattern: $X.equal?(0)
severity: info
message: "Avoid identity checks with literals; use == (and nil? for nil)"
YAML

  cat >"$AST_RULE_DIR/bare-rescue.yml" <<'YAML'
id: rb.bare-rescue
language: ruby
rule:
  pattern: |
    begin
      $A
    rescue
      $B
    end
severity: warning
message: "Bare rescue catches StandardError broadly; rescue specific errors"
YAML

  cat >"$AST_RULE_DIR/rescue-exception.yml" <<'YAML'
id: rb.rescue-exception
language: ruby
rule:
  pattern: |
    begin
      $A
    rescue Exception => $e
      $B
    end
severity: critical
message: "Rescuing Exception also catches system exits/interrupts; avoid"
YAML

  cat >"$AST_RULE_DIR/raise-e.yml" <<'YAML'
id: rb.raise-e
language: ruby
rule:
  pattern: |
    begin
      $A
    rescue $E => $ex
      raise $ex
    end
severity: warning
message: "Use 'raise' (without arg) to preserve original backtrace"
YAML

  cat >"$AST_RULE_DIR/mutable-const.yml" <<'YAML'
id: rb.mutable-const
language: ruby
rule:
  any:
    - pattern: CONST = []
    - pattern: CONST = {}
severity: info
message: "Mutable constants may be modified; consider freezing or dup on read"
YAML

  cat >"$AST_RULE_DIR/eval-exec.yml" <<'YAML'
id: rb.eval-exec
language: ruby
rule:
  any:
    - pattern: eval($$)
    - pattern: instance_eval($$)
    - pattern: class_eval($$)
severity: critical
message: "eval*/_*eval with strings can lead to code injection"
YAML

  cat >"$AST_RULE_DIR/marshal-load.yml" <<'YAML'
id: rb.marshal-load
language: ruby
rule:
  any:
    - pattern: Marshal.load($$)
    - pattern: Marshal.restore($$)
severity: critical
message: "Unmarshalling untrusted data is insecure; prefer JSON or safer formats"
YAML

  cat >"$AST_RULE_DIR/yaml-unsafe.yml" <<'YAML'
id: rb.yaml-unsafe
language: ruby
rule:
  pattern: YAML.load($ARGS)
  not:
    has:
      pattern: permitted_classes=$P
severity: warning
message: "YAML.load may instantiate objects; prefer YAML.safe_load with permitted_classes"
YAML

  cat >"$AST_RULE_DIR/digest-weak.yml" <<'YAML'
id: rb.digest-weak
language: ruby
rule:
  any:
    - pattern: Digest::MD5.hexdigest($$)
    - pattern: Digest::SHA1.hexdigest($$)
severity: warning
message: "Weak hash algorithm (MD5/SHA1); prefer SHA256/512"
YAML

  cat >"$AST_RULE_DIR/random-insecure.yml" <<'YAML'
id: rb.random-insecure
language: ruby
rule:
  any:
    - pattern: rand($$)
    - pattern: Random.rand($$)
severity: info
message: "rand/Random are not cryptographic; use SecureRandom for secrets/tokens"
YAML

  cat >"$AST_RULE_DIR/http-verify-none.yml" <<'YAML'
id: rb.http-verify-none
language: ruby
rule:
  any:
    - pattern: OpenSSL::SSL::VERIFY_NONE
    - pattern: $OBJ.verify_mode = OpenSSL::SSL::VERIFY_NONE
severity: warning
message: "SSL verification disabled; enable peer verification"
YAML

  cat >"$AST_RULE_DIR/send-dynamic.yml" <<'YAML'
id: rb.send-dynamic
language: ruby
rule:
  any:
    - pattern: $OBJ.send($NAME, $$)
    - pattern: $OBJ.__send__($NAME, $$)
severity: info
message: "Dynamic dispatch via send; ensure $NAME is validated"
YAML

  cat >"$AST_RULE_DIR/sql-interp.yml" <<'YAML'
id: rb.sql-interp
language: ruby
rule:
  any:
    - pattern: "DB[$SQL]"
    - pattern: "ActiveRecord::Base.connection.execute($SQL)"
  has:
    pattern: "#{$VAR}"
severity: warning
message: "Interpolated SQL; prefer parameterized queries (e.g., where(name: ?))"
YAML

  # ── Done writing rules ────────────────────────────────────────────────────
}

run_ast_rules() {
  [[ "$HAS_AST_GREP" -eq 1 && -n "$AST_RULE_DIR" ]] || return 1
  local outfmt="--json"; [[ "$FORMAT" == "sarif" ]] && outfmt="--sarif"
  if "${AST_GREP_CMD[@]}" scan -r "$AST_RULE_DIR" "$PROJECT_DIR" $outfmt 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# Bundler/toolchain helpers
# ────────────────────────────────────────────────────────────────────────────
check_bundler() {
  if command -v bundle >/dev/null 2>&1 && [[ -f "$PROJECT_DIR/Gemfile" ]]; then
    HAS_BUNDLE=1; BUNDLE_EXEC=(bundle exec); return 0
  fi
  HAS_BUNDLE=0; BUNDLE_EXEC=(); return 1
}

run_rb_tool_text() {
  # run_rb_tool_text <tool> [args...]
  local tool="$1"; shift || true
  if [[ "$ENABLE_BUNDLER_TOOLS" -eq 1 && "$HAS_BUNDLE" -eq 1 ]]; then
    with_timeout "$RB_TIMEOUT" "${BUNDLE_EXEC[@]}" "$tool" "$@" || true
  else
    if command -v "$tool" >/dev/null 2>&1; then
      with_timeout "$RB_TIMEOUT" "$tool" "$@" || true
    fi
  fi
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
# Init
# ────────────────────────────────────────────────────────────────────────────
maybe_clear

echo -e "${BOLD}${CYAN}"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════════╗
║  ██╗   ██╗██╗  ████████╗██╗███╗   ███╗ █████╗ ████████╗███████╗  ║
║  ██║   ██║██║  ╚══██╔══╝██║████╗ ████║██╔══██╗╚══██╔══╝██╔════╝  ║
║  ██║   ██║██║     ██║   ██║██╔████╔██║███████║   ██║   █████╗    ║
║  ██║   ██║██║     ██║   ██║██║╚██╔╝██║██╔══██║   ██║   ██╔══╝    ║
║  ╚██████╔╝███████╗██║   ██║██║ ╚═╝ ██║██║  ██║   ██║   ███████╗  ║
║   ╚═════╝ ╚══════╝╚═╝   ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝  ║
║                                     __________________           ║
║  ██████╗ ██╗   ██╗ ██████╗        .-'  \ _.-''-._ /  '-.         ║
║  ██╔══██╗██║   ██║██╔════╝      .-/\   .'.      .'.   /\-.       ║
║  ██████╔╝██║   ██║██║  ███╗    _'/  \.'   '.  .'   './  \'_      ║
║  ██╔══██╗██║   ██║██║   ██║   :======:======::======:======:     ║
║  ██████╔╝╚██████╔╝╚██████╔╝    '. '.  \     ''     /  .' .'      ║
║  ╚═════╝  ╚═════╝  ╚═════╝       '. .  \   :  :   /  . .'        ║
║                                    '.'  \  '  '  /  '.'          ║
║                                      ':  \:    :/  :'            ║
║                                        '. \    / .'              ║
║                                          '.\  /.'                ║
║                                            '\/'                  ║
║  ███████╗  ██████╗   █████╗ ███╗   ██╗███╗   ██╗███████╗██████╗  ║
║  ██╔════╝  ██╔═══╝  ██╔══██╗████╗  ██║████╗  ██║██╔════╝██╔══██╗ ║
║  ███████╗  ██║      ███████║██╔██╗ ██║██╔██╗ ██║█████╗  ██████╔╝ ║
║  ╚════██║  ██║      ██╔══██║██║╚██╗██║██║╚██╗██║██╔══╝  ██╔══██╗ ║
║  ███████║  ██████╗  ██║  ██║██║ ╚████║██║ ╚████║███████╗██║  ██║ ║
║  ╚══════╝  ╚═════╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝      ║
║                                                                  ║
║  Ruby module • Rails security, metaprogramming, bundler audits   ║
║  UBS module: ruby • Rubocop, Brakeman, bundler-audit automation  ║
║  ASCII homage: Joan G. Stark gemstone sketch                     ║
║  Run standalone: modules/ubs-ruby.sh --help                      ║
║                                                                  ║
║  Night Owl QA                                                    ║
║  “We see bugs before you do.”                                    ║
╚══════════════════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"

say "${WHITE}Project:${RESET}  ${CYAN}$PROJECT_DIR${RESET}"
say "${WHITE}Started:${RESET}  ${GRAY}$(eval "$DATE_CMD")${RESET}"

# Count files with robust find
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

# ast-grep availability
echo ""
if check_ast_grep; then
  say "${GREEN}${CHECK} ast-grep available (${AST_GREP_CMD[*]}) - full AST analysis enabled${RESET}"
  write_ast_rules || true
else
  say "${YELLOW}${WARN} ast-grep unavailable - using regex fallback mode${RESET}"
fi

# bundler availability
if check_bundler; then
  say "${GREEN}${CHECK} Bundler detected - ${DIM}will run extra analyzers via bundle exec${RESET}"
else
  say "${YELLOW}${WARN} Bundler or Gemfile not detected - will run tools if globally installed${RESET}"
fi

# relax pipefail for scanning (optional)
begin_scan_section

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 1: NIL / DEFENSIVE PROGRAMMING
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 1; then
print_header "1. NIL / DEFENSIVE PROGRAMMING"
print_category "Detects: nil equality, deep method chains without guards, dig? usage" \
  "Prefer x.nil?, safe navigation (&.), and Hash#dig to avoid NoMethodError."

print_subheader "== nil or != nil (prefer .nil?)"
count=$("${GREP_RN[@]}" -e "==[[:space:]]*nil|!=[[:space:]]*nil" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then
  print_finding "warning" "$count" "Equality to nil" "Use x.nil? / !x.nil?"
  show_detailed_finding "==[[:space:]]*nil|!=[[:space:]]*nil" 5
else
  print_finding "good" "No nil equality comparisons"
fi

print_subheader "Deep method chains (use &. / guards)"
deep_chain_json=""
guarded_chain_count=0
count=
if [[ "$HAS_AST_GREP" -eq 1 ]]; then
  deep_chain_json=$(analyze_rb_chain_guards "$DETAIL_LIMIT")
  if [[ -n "$deep_chain_json" ]]; then
    parsed_counts=""
    parsed_counts=$(python3 - <<'PY' <<<"$deep_chain_json"
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    pass
else:
    print(f"{data.get('unguarded', 0)} {data.get('guarded', 0)}")
PY
)
    if [[ -n "$parsed_counts" ]]; then
      read -r count guarded_chain_count <<<"$parsed_counts"
    else
      deep_chain_json=""
    fi
  fi
fi
if [[ -z "${count:-}" ]]; then
  count=$(
    ast_search '$X.$Y.$Z.$W' \
    || ( "${GREP_RN[@]}" -e "\.[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*" "$PROJECT_DIR" 2>/dev/null || true ) | count_lines
  )
  guarded_chain_count=0
fi
if [ "$count" -gt 15 ]; then
  print_finding "info" "$count" "Fragile deep chaining" "Consider &. or guard clauses"
  if [[ -n "$deep_chain_json" ]]; then
    show_ast_samples_from_json "$deep_chain_json"
  else
    show_detailed_finding "\.[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*" 3
  fi
elif [ "$count" -gt 0 ]; then
  print_finding "info" "$count" "Some deep chaining detected"
  [[ -n "$deep_chain_json" ]] && show_ast_samples_from_json "$deep_chain_json"
elif [ "$guarded_chain_count" -gt 0 ]; then
  print_finding "good" "$guarded_chain_count" "Deep chains guarded" "Scanner suppressed method chains guarded by explicit if blocks"
fi
if [[ -n "$deep_chain_json" && "$guarded_chain_count" -gt 0 ]]; then
  say "    ${DIM}Suppressed $guarded_chain_count guarded chain(s) detected inside if statements${RESET}"
fi
if [[ -n "$deep_chain_json" ]]; then
  persist_metric_json "deep_guard" "$deep_chain_json"
fi

print_subheader "Hash#[] chained without dig"
count=$("${GREP_RN[@]}" -e "\[[^\]]+\]\[[^\]]+\]" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 8 ]; then
  print_finding "info" "$count" "Nested [] access" "Consider Hash#dig(:a,:b)"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 2: NUMERIC / ARITHMETIC PITFALLS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 2; then
print_header "2. NUMERIC / ARITHMETIC PITFALLS"
print_category "Detects: division by variable, float equality, modulo hazards" \
  "Guard divisors and avoid exact float equality."

print_subheader "Division by variable (possible ÷0)"
count=$(
  ( "${GREP_RN[@]}" -e "/[[:space:]]*[A-Za-z_][A-Za-z0-9_]*" "$PROJECT_DIR" 2>/dev/null || true ) \
  | (grep -Ev "/[[:space:]]*(255|2|10|100|1000)\b|//|/\*" || true) | count_lines)
if [ "$count" -gt 25 ]; then
  print_finding "warning" "$count" "Division by variable - verify non-zero" "Guard: raise if denom.zero?"
  show_detailed_finding "/[[:space:]]*[A-Za-z_][A-Za-z0-9_]*" 5
elif [ "$count" -gt 0 ]; then
  print_finding "info" "$count" "Division operations found - check divisors"
fi

print_subheader "Float equality (==)"
count=$("${GREP_RN[@]}" -e "==[[:space:]]*[0-9]+\.[0-9]+" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 3 ]; then
  print_finding "warning" "$count" "Float equality comparison" "Use tolerance: (a-b).abs < EPS"
  show_detailed_finding "==[[:space:]]*[0-9]+\.[0-9]+" 3
fi

print_subheader "Modulo by variable (verify non-zero)"
count=$("${GREP_RN[@]}" -e "%[[:space:]]*[A-Za-z_][A-Za-z0-9_]*" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 10 ]; then
  print_finding "info" "$count" "Modulo operations - verify divisor non-zero"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 3: COLLECTION SAFETY
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 3; then
print_header "3. COLLECTION SAFETY"
print_category "Detects: index risks, mutation during iteration, length checks" \
  "Collection misuse leads to IndexError or subtle logic bugs."

print_subheader "Index arithmetic like arr[i±1]"
count=$("${GREP_RN[@]}" -e "\[[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[+\-][[:space:]]*[0-9]+[[:space:]]*\]" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 12 ]; then
  print_finding "warning" "$count" "Array index arithmetic - verify bounds" "Ensure i±k within range"
  show_detailed_finding "\[[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[+\-][[:space:]]*[0-9]+[[:space:]]*\]" 5
elif [ "$count" -gt 0 ]; then
  print_finding "info" "$count" "Index arithmetic present - review bounds"
fi

print_subheader "Mutation during each/map"
count=$("${GREP_RN[@]}" -e "\.(each|map|select|reject)\b" "$PROJECT_DIR" 2>/dev/null | \
  (grep -A3 -E "\.(push|<<|insert|delete|delete_if|pop|shift|unshift|clear)\b" || true) | \
  (grep -c -E "(push|<<|insert|delete|delete_if|pop|shift|unshift|clear)" || true) )
count=$(printf '%s\n' "$count" | awk 'END{print $0+0}')
if [ "$count" -gt 5 ]; then
  print_finding "warning" "$count" "Possible mutation during iteration" "Iterate over dup or collect to new array"
fi

print_subheader "length/size explicit zero checks"
count=$("${GREP_RN[@]}" -e "\.(length|size)[[:space:]]*(==|!=|<|>|<=|>=)[[:space:]]*0" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 8 ]; then
  print_finding "info" "$count" "length/size == 0 checks" "Prefer empty?/any?"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 4: COMPARISON & IDIOMS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 4; then
print_header "4. COMPARISON & IDIOMS"
print_category "Detects: 'and/or' precedence, object identity, case equality misuse" \
  "Prefer &&/|| for precedence; avoid === misuse outside case."

print_subheader "'and'/'or' usage (precedence traps)"
count=$("${GREP_RN[@]}" -e "[^&] and [^&]|[^|] or [^|]" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 3 ]; then
  print_finding "info" "$count" "and/or used; precedence differs from &&/||" "Prefer &&/|| in expressions"
fi

print_subheader "Case equality (===) outside case/when"
count=$("${GREP_RN[@]}" -e "===[[:space:]]*[A-Za-z_]" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v "when[[:space:]]" || true) | count_lines)
if [ "$count" -gt 0 ]; then
  print_finding "info" "$count" "=== used directly" "Ensure intent; === can be surprising"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 5: EXCEPTIONS & ERROR HANDLING
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 5; then
print_header "5. EXCEPTIONS & ERROR HANDLING"
print_category "Detects: bare rescue, rescue Exception, swallowed errors, raise e" \
  "Proper exception handling preserves backtraces and avoids masking bugs."

print_subheader "Bare rescue"
count=$("${GREP_RN[@]}" -e "^[[:space:]]*rescue[[:space:]]*($|#)" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then
  print_finding "warning" "$count" "Bare rescue without class" "Rescue specific errors"
  show_detailed_finding "^[[:space:]]*rescue[[:space:]]*($|#)" 5
else
  print_finding "good" "No bare rescue blocks"
fi

print_subheader "rescue Exception"
count=$("${GREP_RN[@]}" -e "rescue[[:space:]]+Exception" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then
  print_finding "critical" "$count" "Rescuing Exception" "Rescue StandardError or specific subclasses"
  show_detailed_finding "rescue[[:space:]]+Exception" 5
fi

print_subheader "rescue => e; raise e"
count=$("${GREP_RN[@]}" -e "rescue[[:space:]]+[^=]+=>[[:space:]]*[A-Za-z_][A-Za-z0-9_]*" "$PROJECT_DIR" 2>/dev/null | \
  (grep -A2 -E "raise[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$" || true) | \
  (grep -c -E "raise[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$" || true))
count=$(printf '%s\n' "$count" | awk 'END{print $0+0}')
if [ "$count" -gt 0 ]; then
  print_finding "warning" "$count" "Use 'raise' not 'raise e' to keep traceback"
fi

print_subheader "rescue modifier (foo rescue nil)"
count=$("${GREP_RN[@]}" -e "rescue[[:space:]]+nil" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 2 ]; then
  print_finding "warning" "$count" "Silencing errors with 'rescue nil'" "Log or handle specifically"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 6: SECURITY VULNERABILITIES
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 6; then
print_header "6. SECURITY VULNERABILITIES"
print_category "Detects: code injection, unsafe deserialization, TLS off, weak crypto" \
  "Security bugs expose users to attacks and data breaches."

print_subheader "eval/instance_eval/class_eval"
count=$("${GREP_RN[@]}" -e "(^|[^A-Za-z0-9_])(eval|instance_eval|class_eval)[[:space:]]*\(" "$PROJECT_DIR" 2>/dev/null | \
  (grep -Ev "^[[:space:]]*#" || true) | count_lines)
if [ "$count" -gt 0 ]; then
  print_finding "critical" "$count" "eval*/_*eval present" "Avoid executing dynamic code"
  show_detailed_finding "(^|[^A-Za-z0-9_])(eval|instance_eval|class_eval)[[:space:]]*\(" 5
else
  print_finding "good" "No eval*/_*eval detected"
fi

print_subheader "Marshal/YAML unsafe loads"
count=$("${GREP_RN[@]}" -e "Marshal\.(load|restore)\(|YAML\.load\(" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v "YAML\.safe_load" || true) | count_lines)
if [ "$count" -gt 0 ]; then
  print_finding "critical" "$count" "Unsafe deserialization" "Use YAML.safe_load or JSON"
  show_detailed_finding "Marshal\.(load|restore)\(|YAML\.load\(" 5
fi

print_subheader "Backticks / %x() command execution"
count=$("${GREP_RN[@]}" -e '\`[^`]*\`|%x\([^)]*\)' "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then
  print_finding "warning" "$count" "Backtick command execution" "Prefer system with argv array and validate inputs"
  show_detailed_finding '\`[^`]*\`|%x\([^)]*\)' 3
fi

print_subheader "system/exec with single string (shell)"
count=$("${GREP_RN[@]}" -e "(^|[^A-Za-z0-9_])(system|exec|Open3\.(capture2|capture3|popen3))\((['\"]).*\1\)" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v "," || true) | count_lines)
if [ "$count" -gt 0 ]; then
  print_finding "critical" "$count" "Shell invocation risk (single-string)" "Use argv array: system('cmd', arg1, ...)"
  show_detailed_finding "(^|[^A-Za-z0-9_])(system|exec|Open3\.(capture2|capture3|popen3))\(" 3
fi

print_subheader "TLS verify disabled"
count=$("${GREP_RN[@]}" -e "VERIFY_NONE|verify_mode[[:space:]]*=[[:space:]]*OpenSSL::SSL::VERIFY_NONE" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then
  print_finding "warning" "$count" "SSL verification disabled" "Enable VERIFY_PEER"
  show_detailed_finding "VERIFY_NONE|verify_mode[[:space:]]*=" 3
fi

print_subheader "Weak hash algorithms"
count=$("${GREP_RN[@]}" -e "Digest::(MD5|SHA1)\.hexdigest" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then
  print_finding "warning" "$count" "Weak hash usage" "Use Digest::SHA256"
  show_detailed_finding "Digest::(MD5|SHA1)\.hexdigest" 3
fi

print_subheader "Hardcoded secrets"
count=$("${GREP_RNI[@]}" -e "(password|api_?key|secret|token)[[:space:]]*[:=][[:space:]]*['\"][^\"']+['\"]" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v "#.*(password|api_?key|secret|token)" || true) | count_lines)
if [ "$count" -gt 0 ]; then
  print_finding "critical" "$count" "Potential hardcoded secrets" "Use env vars or credentials store"
  show_detailed_finding "(password|api_?key|secret|token)[[:space:]]*[:=][[:space:]]*['\"][^\"']+['\"]" 5
fi

print_subheader "SecureRandom absent where tokens generated"
count=$("${GREP_RN[@]}" -e "token|secret|nonce|password" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v -i "SecureRandom" || true) | count_lines)
if [ "$count" -gt 20 ]; then
  print_finding "info" "$count" "Potential token generation sites" "Ensure SecureRandom is used"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 7: SHELL/SUBPROCESS SAFETY
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 7; then
print_header "7. SHELL / SUBPROCESS SAFETY"
print_category "Detects: system single-string, backticks, Kernel#open pipelines" \
  "Prefer argv array to avoid shell injection."

print_subheader "Kernel#open with pipe"
count=$("${GREP_RN[@]}" -e "open\([[:space:]]*['\"]\|" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "open('|cmd') spawns subshell"; fi

print_subheader "system with interpolation"
count=$("${GREP_RN[@]}" -e "system\((\"|')[^\"']*#\{[^}]+\}[^\"']*(\"|')\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Interpolated shell commands - sanitize inputs"; fi

print_subheader "Preferred exec form"
count=$("${GREP_RN[@]}" -e "system\(['\"][^'\",]+['\"]\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 2 ]; then print_finding "info" "$count" "Use system('cmd', arg1, ...) to avoid shell"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 8: I/O & RESOURCE SAFETY
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 8; then
print_header "8. I/O & RESOURCE SAFETY"
print_category "Detects: File.open without block, Dir.chdir global effects, Tempfile misuse" \
  "Use blocks to auto-close and avoid global state surprises."

print_subheader "File.open without block"
count=$("${GREP_RN[@]}" -e "File\.open\([^\)]*\)" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v -E "do[[:space:]]*\||\{[[:space:]]*\|[^\|]*\|" || true) | count_lines)
if [ "$count" -gt 5 ]; then
  print_finding "warning" "$count" "File.open used without block" "Use File.open(...){|f| ... }"
fi

print_subheader "Dir.chdir (global working dir)"
count=$("${GREP_RN[@]}" -e "Dir\.chdir\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 3 ]; then
  print_finding "info" "$count" "Dir.chdir affects global state" "Prefer chdir blocks or absolute paths"
fi

print_subheader "Tempfile / Dir.mktmpdir without blocks"
count=$("${GREP_RN[@]}" -e "Tempfile\.new\(|Dir\.mktmpdir\(" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v -E "do[[:space:]]*\||\{[[:space:]]*\|[^\|]*\|" || true) | count_lines)
if [ "$count" -gt 0 ]; then print_finding "info" "$count" "Tempfile/tmpdir without block may leak"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 9: PARSING & TYPE CONVERSION
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 9; then
print_header "9. PARSING & TYPE CONVERSION BUGS"
print_category "Detects: JSON.load/parse without rescue, Integer(x) vs to_i, time parsing" \
  "Prefer strict conversions with exceptions where appropriate."

print_subheader "JSON.parse without rescue"
count=$("${GREP_RN[@]}" -e "JSON\.parse\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
trycatch_count=$("${GREP_RNW[@]}" -B2 "begin" "$PROJECT_DIR" 2>/dev/null || true | (grep -c "JSON\.parse" || true))
trycatch_count=$(printf '%s\n' "$trycatch_count" | awk 'END{print $0+0}')
if [ "$count" -gt "$trycatch_count" ]; then
  ratio=$((count - trycatch_count))
  print_finding "warning" "$ratio" "JSON.parse without error handling" "Rescue JSON::ParserError"
fi

print_subheader "String#to_i fallback vs Integer() strict"
count=$("${GREP_RN[@]}" -e "\.to_i(\)|\([[:space:]]*base:" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 20 ]; then
  print_finding "info" "$count" "Frequent to_i usage" "Consider Integer(str, 10) for strictness"
fi

print_subheader "Time.parse without zone/validation"
count=$("${GREP_RN[@]}" -e "Time\.parse\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 5 ]; then print_finding "info" "$count" "Time.parse used" "Validate inputs; prefer iso8601"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 10: CONTROL FLOW GOTCHAS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 10; then
print_header "10. CONTROL FLOW GOTCHAS"
print_category "Detects: return in ensure, retry, nested ternary, next/break in ensure" \
  "Flow pitfalls cause lost exceptions or confusing semantics."

print_subheader "return/break/next inside ensure"
count=$("${GREP_RN[@]}" -e "ensure[[:space:]]*$" "$PROJECT_DIR" 2>/dev/null | \
  (grep -A3 -E "return|break|next" || true) | (grep -c -E "return|break|next" || true) )
count=$(printf '%s\n' "$count" | awk 'END{print $0+0}')
if [ "$count" -gt 0 ]; then
  print_finding "warning" "$count" "Control transfer in ensure" "May swallow exceptions"
fi

print_subheader "Nested ternary (?:)"
count=$("${GREP_RN[@]}" -e "\?.*:[^;]*\?.*:" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 3 ]; then
  print_finding "info" "$count" "Nested ternary expressions" "Prefer if/elsif"
  show_detailed_finding "\?.*:[^;]*\?.*:" 3
fi

print_subheader "retry usage"
count=$("${GREP_RN[@]}" -e "^[[:space:]]*retry[[:space:]]*$" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 2 ]; then
  print_finding "info" "$count" "retry used" "Ensure bounded retries with backoff"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 11: DEBUGGING & PRODUCTION CODE
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 11; then
print_header "11. DEBUGGING & PRODUCTION CODE"
print_category "Detects: puts/p, pry/binding.irb, sensitive logs" \
  "Debug artifacts degrade performance or leak secrets."

print_subheader "puts/p/pp statements"
count=$("${GREP_RN[@]}" -e "^[[:space:]]*(puts|p|pp)\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 40 ]; then
  print_finding "warning" "$count" "Many puts/p/pp statements" "Use Logger with levels"
elif [ "$count" -gt 15 ]; then
  print_finding "info" "$count" "puts/p/pp statements found"
else
  print_finding "good" "Minimal direct printing"
fi

print_subheader "pry/binding.irb/breakpoint"
count=$("${GREP_RN[@]}" -e "binding\.pry|binding\.irb|byebug|debugger" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then
  print_finding "critical" "$count" "Debugger calls present" "Remove before commit"
  show_detailed_finding "binding\.pry|binding\.irb|byebug|debugger" 5
else
  print_finding "good" "No debugger calls"
fi

print_subheader "Logging sensitive data"
count=$("${GREP_RNI[@]}" -e "logger\.(debug|info|warn|error|fatal)\(.*(password|token|secret|Bearer|Authorization)" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then
  print_finding "critical" "$count" "Sensitive data in logs" "Mask or remove secrets"
  show_detailed_finding "logger\.(debug|info|warn|error|fatal)\(.*(password|token|secret|Bearer|Authorization)" 3
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 12: PERFORMANCE & MEMORY
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 12; then
print_header "12. PERFORMANCE & MEMORY"
print_category "Detects: string concat in loops, regex compile in loops, gsub in loops" \
  "Micro-optimizations can matter in hot paths."

print_subheader "String concatenation in loops"
count=$("${GREP_RN[@]}" -e "for[[:space:]]|each[[:space:]]+do|\bwhile[[:space:]]" "$PROJECT_DIR" 2>/dev/null | (grep -A3 "<<\|+=\"" || true) | (grep -cw "<<\|+=\"" || true) )
count=$(printf '%s\n' "$count" | awk 'END{print $0+0}')
if [ "$count" -gt 5 ]; then
  print_finding "info" "$count" "String concat in loops" "Use String#<< with capacity or Array#join"
fi

print_subheader "Regexp.new / %r in loops (compile each iteration)"
count=$("${GREP_RN[@]}" -e "for[[:space:]]|each[[:space:]]+do|\bwhile[[:space:]]" "$PROJECT_DIR" 2>/dev/null | \
  (grep -A3 -E "Regexp\.new\(|%r\{" || true) | (grep -cw "Regexp\.new\|%r\{" || true) )
count=$(printf '%s\n' "$count" | awk 'END{print $0+0}')
if [ "$count" -gt 0 ]; then
  print_finding "info" "$count" "Regex compiled in loop" "Precompile outside loop"
fi

print_subheader "gsub in loops"
count=$("${GREP_RN[@]}" -e "for[[:space:]]|each[[:space:]]+do|\bwhile[[:space:]]" "$PROJECT_DIR" 2>/dev/null | \
  (grep -A3 -E "\.gsub\(" || true) | (grep -cw "\.gsub\(" || true) )
count=$(printf '%s\n' "$count" | awk 'END{print $0+0}')
if [ "$count" -gt 3 ]; then
  print_finding "info" "$count" "gsub in loops" "Consider bulk operations"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 13: VARIABLE & SCOPE
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 13; then
print_header "13. VARIABLE & SCOPE"
print_category "Detects: global variables, class variables, monkey patching core" \
  "Scope issues cause hard-to-debug conflicts and side effects."

print_subheader "Global variables ($var)"
count=$("${GREP_RN[@]}" -e "[$][A-Za-z_][A-Za-z0-9_]*" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 10 ]; then
  print_finding "warning" "$count" "Use of global variables" "Prefer dependency injection or constants"
elif [ "$count" -gt 0 ]; then
  print_finding "info" "$count" "Some globals present"
fi

print_subheader "Class variables (@@var)"
count=$("${GREP_RN[@]}" -e "@@[A-Za-z_][A-Za-z0-9_]*" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 5 ]; then
  print_finding "info" "$count" "Class variables used" "Prefer class instance variables"
fi

print_subheader "Core class reopen (monkey patch)"
count=$("${GREP_RN[@]}" -e "^[[:space:]]*class[[:space:]]+(String|Array|Hash|Numeric|Integer|Float|Symbol|Object|Kernel)\b" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Monkey patching core classes"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 14: CODE QUALITY MARKERS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 14; then
print_header "14. CODE QUALITY MARKERS"
print_category "Detects: TODO, FIXME, HACK, XXX, NOTE" \
  "Technical debt markers indicate incomplete or problematic code."

todo_count=$("${GREP_RNI[@]}" "TODO" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
fixme_count=$("${GREP_RNI[@]}" "FIXME" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
hack_count=$("${GREP_RNI[@]}" "HACK" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
xxx_count=$("${GREP_RNI[@]}" "XXX" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
note_count=$("${GREP_RNI[@]}" "NOTE" "$PROJECT_DIR" 2>/dev/null | count_lines || true)

total_markers=$((todo_count + fixme_count + hack_count + xxx_count))
if [ "$total_markers" -gt 20 ]; then
  print_finding "warning" "$total_markers" "Significant technical debt" "Create tracking tickets"
elif [ "$total_markers" -gt 10 ]; then
  print_finding "info" "$total_markers" "Moderate technical debt"
elif [ "$total_markers" -gt 0 ]; then
  print_finding "info" "$total_markers" "Minimal technical debt"
else
  print_finding "good" "No technical debt markers"
fi
if [ "$total_markers" -gt 0 ]; then
  say "\n  ${DIM}Breakdown:${RESET}"
  [ "$todo_count" -gt 0 ] && say "    ${YELLOW}TODO:${RESET}  $todo_count"
  [ "$fixme_count" -gt 0 ] && say "    ${RED}FIXME:${RESET} $fixme_count"
  [ "$hack_count" -gt 0 ] && say "    ${MAGENTA}HACK:${RESET}  $hack_count"
  [ "$xxx_count" -gt 0 ] && say "    ${RED}XXX:${RESET}   $xxx_count"
  [ "$note_count" -gt 0 ] && say "    ${BLUE}NOTE:${RESET}  $note_count"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 15: REGEX & STRING SAFETY
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 15; then
print_header "15. REGEX & STRING SAFETY"
print_category "Detects: ReDoS, dynamic regex with input, escaping issues" \
  "Regex bugs cause performance issues and security vulnerabilities."

print_subheader "Nested quantifiers (ReDoS risk)"
count=$("${GREP_RN[@]}" -e "\([^)]*\+[^)]*\)\+|\([^)]*\*[^)]*\)\+" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 3 ]; then
  print_finding "warning" "$count" "Potential catastrophic regex" "Use atomic groups or simplify patterns"
  show_detailed_finding "\([^)]*\+[^)]*\)\+|\([^)]*\*[^)]*\)\+" 2
fi

print_subheader "Regexp.new from variables"
count=$("${GREP_RN[@]}" -e "Regexp\.new\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\)" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 3 ]; then
  print_finding "info" "$count" "Dynamic regex construction" "Sanitize inputs or anchor carefully"
fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 16: CONCURRENCY & PARALLELISM
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 16; then
print_header "16. CONCURRENCY & PARALLELISM"
print_category "Detects: Thread.new without join, Ractor misuse patterns" \
  "Concurrency bugs lead to leaks and nondeterminism."

print_subheader "Thread.new without join at callsite"
count=$("${GREP_RN[@]}" -e "Thread\.new\(" "$PROJECT_DIR" 2>/dev/null | \
  (grep -v -E "\.join|\bjoin\b" || true) | count_lines )
if [ "$count" -gt 0 ]; then
  print_finding "info" "$count" "Detached threads" "Ensure lifecycle, join, or thread pool"
fi

print_subheader "Ractor.new heavy usage"
count=$("${GREP_RN[@]}" -e "Ractor\.new\(" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "info" "$count" "Ractor usage - verify isolation & shareable objects"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 17: RUBY/RAILS PRACTICALS
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 17; then
print_header "17. RUBY/RAILS PRACTICALS"
print_category "Detects: frozen_string_literal pragma, mass assignment hints, csrf skip" \
  "Rails conventions and Ruby pragmas that impact safety/perf."

print_subheader "Missing 'frozen_string_literal: true' pragma (heuristic)"
rb_files=$(
  ( set +o pipefail; find "$PROJECT_DIR" "${EX_PRUNE[@]}" -o \( -type f -name "*.rb" -print \) 2>/dev/null || true )
)
missing_pragma=0
while IFS= read -r f; do
  # check first two lines for pragma
  if ! head -n 2 "$f" 2>/dev/null | grep -q "frozen_string_literal:\s*true"; then
    missing_pragma=$((missing_pragma+1))
  fi
done <<<"$rb_files"
if [ "$missing_pragma" -gt 25 ]; then
  print_finding "info" "$missing_pragma" "Files missing frozen_string_literal pragma" "Consider enabling globally if beneficial"
fi

print_subheader "Rails: protect_from_forgery skipped?"
count=$("${GREP_RN[@]}" -e "skip_before_action[[:space:]]+:verify_authenticity_token" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "CSRF protections skipped in controllers"; fi

print_subheader "Rails: strong parameters bypass (permit!)"
count=$("${GREP_RN[@]}" -e "\.permit!\b" "$PROJECT_DIR" 2>/dev/null | count_lines || true)
if [ "$count" -gt 0 ]; then print_finding "warning" "$count" "Strong params permit! found - review carefully"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 18: AST-GREP RULE PACK FINDINGS (JSON/SARIF passthrough)
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 18; then
print_header "AST-GREP RULE PACK FINDINGS"
  if [[ "$HAS_AST_GREP" -eq 1 && -n "$AST_RULE_DIR" ]]; then
    if run_ast_rules; then
      say "${DIM}${INFO} Above JSON/SARIF lines are ast-grep matches (id, message, severity, file/pos).${RESET}"
      if [[ "$FORMAT" == "sarif" ]]; then
        say "${DIM}${INFO} Tip: ${BOLD}${AST_GREP_CMD[*]} scan -r $AST_RULE_DIR \"$PROJECT_DIR\" --sarif > report.sarif${RESET}"
      fi
    else
      say "${YELLOW}${WARN} ast-grep scan subcommand unavailable; rule-pack mode skipped.${RESET}"
    fi
  else
    say "${YELLOW}${WARN} ast-grep not available; install ast-grep or skip category 18.${RESET}"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CATEGORY 19: BUNDLER-POWERED EXTRA ANALYZERS (optional)
# ═══════════════════════════════════════════════════════════════════════════
if should_skip 19; then
print_header "19. BUNDLER-POWERED EXTRA ANALYZERS"
print_category "Rubocop (lint), Brakeman (Rails security), Bundler-Audit (deps), Reek (smells), Fasterer (perf)" \
  "These tools augment ast-grep/rg results."

if [[ "$ENABLE_BUNDLER_TOOLS" -eq 1 ]]; then
  IFS=',' read -r -a RBTOOLS <<< "$RB_TOOLS"
  for TOOL in "${RBTOOLS[@]}"; do
    case "$TOOL" in
      rubocop)
        print_subheader "rubocop (lint/style)"
        run_rb_tool_text rubocop --format clang --force-exclusion "$PROJECT_DIR" || true
        ;;
      brakeman)
        print_subheader "brakeman (Rails security)"
        if [[ -d "$PROJECT_DIR/app" || -d "$PROJECT_DIR/config" ]]; then
          run_rb_tool_text brakeman -q -w2 -z "$PROJECT_DIR" || true
        else
          say "  ${GRAY}${INFO} Rails app structure not detected; brakeman may be N/A${RESET}"
          run_rb_tool_text brakeman -q -z "$PROJECT_DIR" || true
        fi
        ;;
      bundler-audit)
        print_subheader "bundler-audit (dependency vulns)"
        if [[ "$HAS_BUNDLE" -eq 1 && -f "$PROJECT_DIR/Gemfile.lock" ]]; then
          run_rb_tool_text bundle audit check --update || true
        else
          say "  ${GRAY}${INFO} Gemfile.lock not found or bundler missing; skipping bundler-audit${RESET}"
        fi
        ;;
      reek)
        print_subheader "reek (code smells)"
        run_rb_tool_text reek --single-line "$PROJECT_DIR" || true
        ;;
      fasterer)
        print_subheader "fasterer (perf idioms)"
        run_rb_tool_text fasterer "$PROJECT_DIR" || true
        ;;
      *)
        say "  ${GRAY}${INFO} Unknown tool '$TOOL' ignored${RESET}"
        ;;
    esac
  done
else
  say "  ${GRAY}${INFO} bundler-based analyzers disabled (--no-bundler)${RESET}"
fi
fi

# restore pipefail if we relaxed it
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
say "${DIM}Add to pre-commit: ./ubs --ci --fail-on-warning . > rb-bug-scan-report.txt${RESET}"
echo ""

EXIT_CODE=0
if [ "$CRITICAL_COUNT" -gt 0 ]; then EXIT_CODE=1; fi
if [ "$FAIL_ON_WARNING" -eq 1 ] && [ $((CRITICAL_COUNT + WARNING_COUNT)) -gt 0 ]; then EXIT_CODE=1; fi
exit "$EXIT_CODE"
