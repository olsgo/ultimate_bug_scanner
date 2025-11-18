# UBS Language Modules

Each `ubs-<lang>.sh` provides a consistent CLI (current modules: `js`, `python`, `cpp`, `rust`, `golang`, `java`, `ruby`, `swift`):

```
ubs-<lang>.sh [PROJECT_DIR] [options]

Options:
--format=FMT       text|json|sarif (default: text)
--ci               stable timestamps (UTC ISO8601)
--fail-on-warning  exit non-zero if any warnings or critical
-v, --verbose      print more samples in text mode
--jobs=N           parallel hint (propagated to ripgrep/child tools)
-h, --help         this help
```

Responsibilities:
- Detect files for the given language
- Apply fast heuristics using ripgrep/grep (or language-native tooling)
- Emit native JSON/SARIF where possible so the meta-runner never needs to parse text
- Exit non-zero on critical issues (or warnings when `--fail-on-warning` is set)

Modules are auto-downloaded by the `ubs` meta-runner with this priority:
1. User PATH (`ubs-<lang>` available globally)
2. Local repository `modules/ubs-<lang>.sh`
3. Cached modules under `${XDG_DATA_HOME:-$HOME/.local/share}/ubs/modules`

When a module is missing, `ubs` fetches it from
`https://raw.githubusercontent.com/Dicklesworthstone/ultimate_bug_scanner/master/modules/ubs-<lang>.sh`,
validates the shebang, marks it executable, and caches it for future runs.
