# Ultimate Bug Scanner - Test Suite

This test suite provides comprehensive examples of buggy and clean JavaScript code for validating the bug scanner's detection capabilities.

## 📁 Directory Structure

```
test-suite/
├── buggy/          # Code with intentional bugs (scanner SHOULD find issues)
│   ├── 01-null-safety.js
│   ├── 02-security.js
│   ├── 03-async-await.js
│   ├── 04-memory-leaks.js
│   ├── 05-type-coercion.js
│   ├── 06-math-errors.js
│   ├── 07-error-handling.js
│   ├── 08-control-flow.js
│   ├── 09-debugging-production.js
│   ├── 10-variable-scope.js
│   └── 11-combined-issues.js
│
├── clean/          # Best practices code (scanner should pass with minimal issues)
│   ├── 01-null-safety-clean.js
│   ├── 02-security-clean.js
│   └── 03-async-await-clean.js
│
└── README.md       # This file
```

## 🧪 Running Tests

### Scan Individual Buggy Files

```bash
# Test null safety detection
ubs test-suite/buggy/01-null-safety.js

# Test security vulnerability detection
ubs test-suite/buggy/02-security.js

# Test async/await issue detection
ubs test-suite/buggy/03-async-await.js
```

### Scan All Buggy Code

```bash
# Should find MANY issues
ubs test-suite/buggy/

# Verbose output with code samples
ubs -v test-suite/buggy/

# Save report
ubs test-suite/buggy/ test-results-buggy.txt
```

### Scan Clean Code

```bash
# Should find minimal or no critical issues
ubs test-suite/clean/

# Verbose output
ubs -v test-suite/clean/
```

### Comparison Test

```bash
# Scan buggy code and count issues
echo "=== BUGGY CODE ==="
ubs test-suite/buggy/ | grep -E "Critical|Warning|Info"

echo ""
echo "=== CLEAN CODE ==="
ubs test-suite/clean/ | grep -E "Critical|Warning|Info"
```

## 📊 Expected Results

### Buggy Code (test-suite/buggy/)

Each file contains **intentional bugs** that the scanner should detect:

| File | Expected Issues | Primary Categories |
|------|----------------|-------------------|
| `01-null-safety.js` | 10+ CRITICAL | Unguarded property access, missing null checks |
| `02-security.js` | 14+ CRITICAL | eval(), XSS, hardcoded secrets, weak crypto |
| `03-async-await.js` | 14+ CRITICAL/WARNING | Missing await, no error handling, race conditions |
| `04-memory-leaks.js` | 13+ WARNING | Event listeners, timers, DOM queries in loops |
| `05-type-coercion.js` | 13+ CRITICAL/WARNING | Loose equality, NaN comparison, type confusion |
| `06-math-errors.js` | 14+ WARNING | Division by zero, parseInt without radix |
| `07-error-handling.js` | 14+ CRITICAL | Empty catch blocks, throwing strings, no try/catch |
| `08-control-flow.js` | 13+ WARNING | Missing breaks, nested ternaries, unreachable code |
| `09-debugging-production.js` | 12+ CRITICAL | debugger statements, console.log, sensitive data logging |
| `10-variable-scope.js` | 14+ WARNING/CRITICAL | var usage, global pollution, variable shadowing |
| `11-combined-issues.js` | 20+ MIXED | Realistic codebase with multiple bug types |

**Total Expected:** 100+ issues across all categories

### Clean Code (test-suite/clean/)

| File | Expected Issues | Notes |
|------|----------------|-------|
| `01-null-safety-clean.js` | 0-2 | Best practices: optional chaining, null checks, guards |
| `02-security-clean.js` | 0-1 | Safe: textContent, env vars, strong crypto, HTTPS |
| `03-async-await-clean.js` | 0-1 | Proper: try/catch, Promise.all, error handling |

**Total Expected:** 0-5 minor issues (mostly INFO level)

## 🎯 What Each File Tests

### Buggy Files

#### 01-null-safety.js
- Unguarded DOM queries (`getElementById` without null check)
- Deep property access without optional chaining
- Missing array length checks
- Chained method calls on potentially null objects

#### 02-security.js
- **CRITICAL:** `eval()` usage (RCE vulnerability)
- **CRITICAL:** XSS via `innerHTML` with user input
- **CRITICAL:** Hardcoded API keys and secrets
- Weak crypto (MD5, SHA1)
- HTTP URLs in production
- ReDoS vulnerable regex patterns

#### 03-async-await.js
- `await` in non-async function (SyntaxError)
- Missing `await` on async calls
- Promises without `.catch()` or error handling
- `await` inside loops (performance)
- Race conditions
- Floating promises

#### 04-memory-leaks.js
- Event listeners never removed
- `setInterval` without `clearInterval`
- React useEffect without cleanup
- DOM queries in loops
- String concatenation in loops
- Detached DOM nodes

#### 05-type-coercion.js
- Loose equality (`==` instead of `===`)
- Direct NaN comparison
- Wrong typeof string literals
- Global `isNaN()` instead of `Number.isNaN()`
- Implicit type conversions

#### 06-math-errors.js
- Division by zero
- `parseInt` without radix parameter
- Floating-point equality comparisons
- Modulo by zero
- Bitwise operations on non-integers

#### 07-error-handling.js
- Empty catch blocks (swallowing errors)
- Try without finally (resource leaks)
- Throwing strings instead of Error objects
- Generic error messages
- `JSON.parse` without try/catch

#### 08-control-flow.js
- Switch cases without break
- Switch without default case
- Nested ternaries (unreadable)
- Unreachable code
- Empty if/else blocks

#### 09-debugging-production.js
- **CRITICAL:** `debugger` statements left in code
- Excessive `console.log` statements
- Logging sensitive data (passwords, API keys)
- `alert/confirm/prompt` (blocking UI)
- TODO/FIXME markers

#### 10-variable-scope.js
- Using `var` instead of `let`/`const`
- Global variable pollution (missing declarations)
- Variable shadowing
- Loop variable leaking
- Attempting to reassign `const`

#### 11-combined-issues.js
- Realistic simulation of multiple bug types in one file
- Security + async + null safety + performance issues
- Tests scanner's ability to find diverse issues in real-world code

### Clean Files

#### 01-null-safety-clean.js
- ✅ Null checks before property access
- ✅ Optional chaining (`?.`)
- ✅ Nullish coalescing (`??`)
- ✅ Guard clauses
- ✅ Array.isArray checks

#### 02-security-clean.js
- ✅ Using `textContent` instead of `innerHTML`
- ✅ Environment variables for secrets
- ✅ Strong crypto (SHA-256)
- ✅ HTTPS URLs
- ✅ Safe regex patterns

#### 03-async-await-clean.js
- ✅ Proper async/await usage
- ✅ Try/catch error handling
- ✅ `Promise.all()` for parallelization
- ✅ `.catch()` on promises
- ✅ Timeout handling

## 🔬 Validation Checklist

Use this checklist to verify the scanner is working correctly:

### Critical Issue Detection

- [ ] Detects `eval()` usage (02-security.js)
- [ ] Detects `new Function()` (02-security.js)
- [ ] Detects `innerHTML` XSS (02-security.js)
- [ ] Detects hardcoded secrets (02-security.js)
- [ ] Detects `debugger` statements (09-debugging-production.js)
- [ ] Detects NaN direct comparison (05-type-coercion.js, 06-math-errors.js)
- [ ] Detects `await` in non-async function (03-async-await.js)
- [ ] Detects unguarded DOM queries (01-null-safety.js)

### Warning Detection

- [ ] Detects division by zero risk (06-math-errors.js)
- [ ] Detects `parseInt` without radix (06-math-errors.js)
- [ ] Detects promises without `.catch()` (03-async-await.js)
- [ ] Detects event listeners without cleanup (04-memory-leaks.js)
- [ ] Detects `setInterval` without clear (04-memory-leaks.js)
- [ ] Detects loose equality (05-type-coercion.js)
- [ ] Detects empty catch blocks (07-error-handling.js)
- [ ] Detects switch without default (08-control-flow.js)

### Info Detection

- [ ] Detects `var` usage (10-variable-scope.js)
- [ ] Detects `console.log` statements (09-debugging-production.js)
- [ ] Detects TODO/FIXME markers (09-debugging-production.js)
- [ ] Detects optional chaining opportunities (01-null-safety.js)
- [ ] Suggests performance improvements (04-memory-leaks.js)

### Clean Code Recognition

- [ ] Passes clean null safety code (clean/01-null-safety-clean.js)
- [ ] Passes clean security code (clean/02-security-clean.js)
- [ ] Passes clean async code (clean/03-async-await-clean.js)

## 📈 Benchmark Commands

### Comprehensive Test

```bash
#!/bin/bash
# comprehensive-test.sh - Run full test suite validation

echo "=== ULTIMATE BUG SCANNER - TEST SUITE VALIDATION ==="
echo ""

echo "1. Testing buggy code detection..."
BUGGY_CRITICAL=$(ubs test-suite/buggy/ 2>&1 | grep "Critical:" | awk '{print $3}')
BUGGY_WARNING=$(ubs test-suite/buggy/ 2>&1 | grep "Warning:" | awk '{print $3}')
echo "   Buggy code: $BUGGY_CRITICAL critical, $BUGGY_WARNING warnings"

echo ""
echo "2. Testing clean code validation..."
CLEAN_CRITICAL=$(ubs test-suite/clean/ 2>&1 | grep "Critical:" | awk '{print $3}')
CLEAN_WARNING=$(ubs test-suite/clean/ 2>&1 | grep "Warning:" | awk '{print $3}')
echo "   Clean code: $CLEAN_CRITICAL critical, $CLEAN_WARNING warnings"

echo ""
echo "=== VALIDATION RESULTS ==="
if [ "$BUGGY_CRITICAL" -gt 50 ] && [ "$CLEAN_CRITICAL" -lt 3 ]; then
  echo "✅ PASS: Scanner correctly identifies bugs and validates clean code"
else
  echo "❌ FAIL: Scanner may need calibration"
fi
```

### Performance Test

```bash
# Test scanning speed
time ubs test-suite/buggy/

# Expected: < 2 seconds for all buggy files
```

## 🎓 Educational Use

This test suite is ideal for:

1. **Learning JavaScript Pitfalls** - Each buggy file shows real-world mistakes
2. **Testing AI Agents** - Verify AI coding agents can catch these issues
3. **Scanner Development** - Add new bug patterns and test detection
4. **Code Review Training** - Practice identifying common bugs

## 🔧 Adding New Test Cases

To add new test cases:

1. Create a new file in `buggy/` or `clean/`
2. Add clear comments explaining each bug or best practice
3. Include diverse examples
4. Test with scanner: `ubs test-suite/buggy/your-new-file.js`
5. Update this README with expected results

## 📝 Notes

- **Buggy files are intentionally broken** - Do NOT use this code in production!
- **All bugs are clearly commented** for educational purposes
- **Exit codes matter**: Buggy code should exit with code 1, clean code with 0
- **Some files may trigger 100+ issues** - this is expected and demonstrates the scanner's thoroughness

## 🎯 Success Criteria

The scanner passes validation if:

1. ✅ Finds 80%+ of bugs in buggy files
2. ✅ Produces <5 false positives on clean files
3. ✅ Completes full suite scan in <5 seconds
4. ✅ Correctly categorizes issues (CRITICAL vs WARNING vs INFO)
5. ✅ Provides actionable fix suggestions

---

**Run the full test suite now:**

```bash
ubs test-suite/buggy/ && echo "✅ No critical issues in buggy code (UNEXPECTED!)" || echo "✅ Found issues as expected"
ubs test-suite/clean/ && echo "✅ Clean code passed" || echo "❌ False positives in clean code"
```
