package main

import (
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type resourceKind string

const (
	kindContext  resourceKind = "context_cancel"
	kindTicker   resourceKind = "ticker_stop"
	kindTimer    resourceKind = "timer_stop"
	kindFile     resourceKind = "file_handle"
	kindDB       resourceKind = "db_handle"
	kindListener resourceKind = "listener_close"
	kindMutex    resourceKind = "mutex_lock"
)

type resource struct {
	name     string
	kind     resourceKind
	position token.Position
	released bool
}

type analyzer struct {
	fset      *token.FileSet
	resources []*resource
	byName    map[string][]*resource
}

func newAnalyzer(fset *token.FileSet) *analyzer {
	return &analyzer{
		fset:   fset,
		byName: make(map[string][]*resource),
	}
}

func (a *analyzer) add(name string, kind resourceKind, pos token.Position) {
	res := &resource{name: name, kind: kind, position: pos}
	a.resources = append(a.resources, res)
	if name != "" {
		a.byName[name] = append(a.byName[name], res)
	}
}

func (a *analyzer) markReleased(name string, kinds ...resourceKind) {
	if name == "" {
		return
	}
	entries := a.byName[name]
	for _, res := range entries {
		if res.released {
			continue
		}
		if len(kinds) == 0 || containsKind(kinds, res.kind) {
			res.released = true
			return
		}
	}
}

func containsKind(kinds []resourceKind, target resourceKind) bool {
	for _, k := range kinds {
		if k == target {
			return true
		}
	}
	return false
}

func (a *analyzer) inspect(node ast.Node) bool {
	switch n := node.(type) {
	case *ast.AssignStmt:
		a.handleAssign(n)
	case *ast.CallExpr:
		a.handleCall(n)
	}
	return true
}

func (a *analyzer) handleAssign(assign *ast.AssignStmt) {
	if len(assign.Rhs) == 0 {
		return
	}

	// Handle multi-assignment: a, b := f(), g()
	// Or single multi-return: a, b := f()

	// Case 1: Single RHS expression (function returning multiple values)
	if len(assign.Rhs) == 1 {
		call, ok := assign.Rhs[0].(*ast.CallExpr)
		if !ok {
			return
		}
		kind := classifyCall(call)
		if kind == "" {
			return
		}
		names := collectNames(assign.Lhs)
		pos := a.fset.Position(assign.Pos())

		switch kind {
		case kindContext:
			// expect cancel func as last name
			if len(names) >= 2 {
				name := names[len(names)-1]
				if name == "_" {
					name = ""
				}
				a.add(name, kind, pos)
			} else {
				a.add("", kind, pos)
			}
		default:
			// For other resources, the resource is usually the first return value
			if len(names) > 0 {
				name := names[0]
				if name != "" && name != "_" {
					a.add(name, kind, pos)
				}
			}
		}
		return
	}

	// Case 2: Multiple RHS expressions (parallel assignment)
	// a, b := f(), g()
	if len(assign.Lhs) == len(assign.Rhs) {
		names := collectNames(assign.Lhs)
		for i, expr := range assign.Rhs {
			call, ok := expr.(*ast.CallExpr)
			if !ok {
				continue
			}
			kind := classifyCall(call)
			if kind == "" {
				continue
			}
			// In parallel assignment, each RHS returns 1 value (or it's invalid Go)
			// But our tracked resources (os.Open) return (val, err), so they CANNOT appear here
			// EXCEPT: time.NewTicker returns *Ticker (1 value).
			// So we only track single-value returns here.

			name := names[i]
			if name == "" || name == "_" {
				continue
			}

			// Context/Open return multiple values, so they won't be here.
			// Ticker/Timer return 1 value.
			if kind == kindTicker || kind == kindTimer {
				a.add(name, kind, a.fset.Position(assign.Pos()))
			}
		}
	}
}

func classifyCall(call *ast.CallExpr) resourceKind {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return ""
	}
	pkg := exprName(sel.X)
	fn := sel.Sel.Name
	switch {
	case pkg == "context" && (fn == "WithCancel" || fn == "WithTimeout" || fn == "WithDeadline"):
		return kindContext
	case pkg == "time" && fn == "NewTicker":
		return kindTicker
	case pkg == "time" && fn == "NewTimer":
		return kindTimer
	case pkg == "os" && (fn == "Open" || fn == "OpenFile" || fn == "Create" || fn == "CreateTemp"):
		return kindFile
	case pkg == "sql" && (fn == "Open" || fn == "OpenDB"):
		return kindDB
	case pkg == "net" && (fn == "Listen" || fn == "ListenPacket" || fn == "ListenIP" || fn == "ListenTCP" || fn == "ListenUDP" || fn == "ListenUnix"):
		return kindListener
	default:
		return ""
	}
}

func (a *analyzer) handleCall(call *ast.CallExpr) {
	switch fun := call.Fun.(type) {
	case *ast.SelectorExpr:
		name := fun.Sel.Name
		base := exprName(fun.X)
		switch name {
		case "Lock":
			if base != "" {
				a.add(base, kindMutex, a.fset.Position(call.Pos()))
			}
		case "Stop":
			a.markReleased(base, kindTicker, kindTimer)
		case "Close":
			a.markReleased(base, kindFile, kindDB, kindListener)
		case "Unlock":
			a.markReleased(base, kindMutex)
		}
	case *ast.Ident:
		a.markReleased(fun.Name, kindContext)
	}
}

func exprName(expr ast.Expr) string {
	switch v := expr.(type) {
	case *ast.Ident:
		return v.Name
	case *ast.SelectorExpr:
		base := exprName(v.X)
		if base == "" {
			return v.Sel.Name
		}
		return base + "." + v.Sel.Name
	case *ast.StarExpr:
		return exprName(v.X)
	default:
		return ""
	}
}

func collectNames(exprs []ast.Expr) []string {
	names := make([]string, 0, len(exprs))
	for _, expr := range exprs {
		switch v := expr.(type) {
		case *ast.Ident:
			names = append(names, v.Name)
		case *ast.SelectorExpr:
			names = append(names, exprName(v))
		case *ast.StarExpr:
			names = append(names, exprName(v.X))
		default:
			names = append(names, "")
		}
	}
	return names
}

func analyzeFile(path, root string) ([]string, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
	if err != nil {
		return nil, err
	}
	visitor := newAnalyzer(fset)
	ast.Inspect(file, visitor.inspect)

	rel, err := filepath.Rel(root, path)
	if err != nil {
		rel = path
	}
	var issues []string
	for _, res := range visitor.resources {
		if res.released {
			continue
		}
		line := res.position.Line
		location := fmt.Sprintf("%s:%d", rel, line)
		message := formatMessage(res.kind, res.name)
		issues = append(issues, fmt.Sprintf("%s\t%s\t%s", location, res.kind, message))
	}
	return issues, nil
}

func formatMessage(kind resourceKind, name string) string {
	subject := name
	if subject == "" {
		subject = "resource"
	}
	switch kind {
	case kindContext:
		return "context.With* cancel function never invoked"
	case kindTicker:
		return fmt.Sprintf("Ticker %s missing Stop()", subject)
	case kindTimer:
		return fmt.Sprintf("Timer %s missing Stop()", subject)
	case kindFile:
		return fmt.Sprintf("File handle %s opened without Close()", subject)
	case kindDB:
		return fmt.Sprintf("DB handle %s opened without Close()", subject)
	case kindListener:
		return fmt.Sprintf("Listener %s opened without Close()", subject)
	case kindMutex:
		return fmt.Sprintf("Mutex %s locked without Unlock()", subject)
	default:
		return "Resource not released"
	}
}

var ignoreDirs = map[string]struct{}{
	".git":         {},
	"vendor":       {},
	"node_modules": {},
	"testdata":     {},
	"dist":         {},
	"build":        {},
	"bin":          {},
}

func collectGoFiles(root string) ([]string, error) {
	files := []string{}
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if _, skip := ignoreDirs[d.Name()]; skip {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(d.Name(), ".go") {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	return files, nil
}

func main() {
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: resource_lifecycle_go.go <project_dir>")
		os.Exit(2)
	}
	root, err := filepath.Abs(flag.Arg(0))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	files, err := collectGoFiles(root)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	var outputs []string
	for _, file := range files {
		issues, err := analyzeFile(file, root)
		if err != nil {
			continue
		}
		outputs = append(outputs, issues...)
	}
	if len(outputs) > 0 {
		fmt.Println(strings.Join(outputs, "\n"))
	}
}
