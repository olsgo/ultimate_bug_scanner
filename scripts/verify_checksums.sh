#!/usr/bin/env bash
# Verify that module checksums in ubs script match actual module files
# This MUST pass before any tests run

set -euo pipefail

# Change to project root directory
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Verifying module checksums..."

# Extract checksums from ubs script
declare -A EXPECTED_CHECKSUMS
while IFS='=' read -r key value; do
  if [[ $key =~ \[([a-z]+)\] ]]; then
    lang="${BASH_REMATCH[1]}"
    # Remove quotes and whitespace
    checksum=$(echo "$value" | sed "s/['\"]//g" | tr -d ' ')
    EXPECTED_CHECKSUMS[$lang]=$checksum
  fi
done < <(sed -n '/^declare -A MODULE_CHECKSUMS=/,/^)/p' ubs | grep '^\s*\[')

# Verify each module
FAILED=0
for module in modules/ubs-*.sh; do
  if [[ ! -f "$module" ]]; then
    continue
  fi
  
  # Extract language from filename
  lang=$(basename "$module" | sed 's/ubs-//;s/\.sh$//')
  
  # Calculate actual checksum
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$module" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$module" | awk '{print $1}')
  else
    echo -e "${RED}ERROR: No checksum tool found (sha256sum or shasum required)${NC}"
    exit 1
  fi
  
  expected="${EXPECTED_CHECKSUMS[$lang]:-MISSING}"
  
  if [[ "$actual" != "$expected" ]]; then
    echo -e "${RED}✗ CHECKSUM MISMATCH: $module${NC}"
    echo -e "  Expected: $expected"
    echo -e "  Actual:   $actual"
    echo -e "${YELLOW}  Run: ./scripts/update_checksums.sh${NC}"
    FAILED=1
  else
    echo -e "${GREEN}✓ $module${NC}"
  fi
done

if [[ $FAILED -eq 1 ]]; then
  echo ""
  echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  CHECKSUM VERIFICATION FAILED                              ║${NC}"
  echo -e "${RED}║                                                            ║${NC}"
  echo -e "${RED}║  Module checksums do NOT match ubs script!                 ║${NC}"
  echo -e "${RED}║  This means the tool will fail for end users.              ║${NC}"
  echo -e "${RED}║                                                            ║${NC}"
  echo -e "${RED}║  Fix: ./scripts/update_checksums.sh                        ║${NC}"
  echo -e "${RED}║  Then: git add ubs && git commit --amend                   ║${NC}"
  echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
  exit 1
fi

echo -e "${GREEN}All checksums verified!${NC}"
