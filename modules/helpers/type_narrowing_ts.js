#!/usr/bin/env node
const fs = require('fs/promises');
const path = require('path');
let ts;
try {
  ts = require('typescript');
} catch (err) {
  ts = null;
}

const projectDir = path.resolve(process.argv[2] || process.cwd());
const SKIP_DIRS = new Set(['.git', '.hg', '.svn', 'node_modules', 'dist', 'build', '.next', '.nuxt', '.turbo', '.expo']);
const EXTENSIONS = new Set(['.ts', '.tsx']);

async function collectFiles(dir) {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  const batches = await Promise.all(entries.map(async (entry) => {
    if (SKIP_DIRS.has(entry.name)) return [];
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name.startsWith('.') && entry.name.length > 1) return [];
      return collectFiles(fullPath);
    }
    if (EXTENSIONS.has(path.extname(entry.name).toLowerCase())) {
      return [fullPath];
    }
    return [];
  }));
  return batches.flat();
}

function formatLocation(file, sourceFile, pos) {
  const lc = sourceFile.getLineAndCharacterOfPosition(pos);
  return `${file}:${lc.line + 1}:${lc.character + 1}`;
}

async function analyzeFileWithTs(filePath) {
  const sourceText = await fs.readFile(filePath, 'utf8');
  const scriptKind = filePath.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  const sourceFile = ts.createSourceFile(filePath, sourceText, ts.ScriptTarget.Latest, true, scriptKind);
  const results = [];

  function extractGuardedIdentifier(expression) {
    if (ts.isBinaryExpression(expression)) {
      const op = expression.operatorToken.kind;
      if (
        op === ts.SyntaxKind.EqualsEqualsToken ||
        op === ts.SyntaxKind.EqualsEqualsEqualsToken
      ) {
        const left = ts.isIdentifier(expression.left) ? expression.left : null;
        const right = ts.isIdentifier(expression.right) ? expression.right : null;
        if (left && isNullish(expression.right)) return left;
        if (right && isNullish(expression.left)) return right;
        if (left && isUndefinedIdent(expression.right)) return left;
        if (right && isUndefinedIdent(expression.left)) return right;
      }
    }
    if (ts.isPrefixUnaryExpression(expression) && expression.operator === ts.SyntaxKind.ExclamationToken) {
      if (ts.isIdentifier(expression.operand)) {
        return expression.operand;
      }
    }
    return null;
  }

  function isNullish(node) {
    return node.kind === ts.SyntaxKind.NullKeyword;
  }

  function isUndefinedIdent(node) {
    return ts.isIdentifier(node) && node.text === 'undefined';
  }

  function blockHasExit(node) {
    if (ts.isReturnStatement(node) || ts.isThrowStatement(node)) return true;
    if (ts.isBlock(node)) return node.statements.some(blockHasExit);
    if (ts.isIfStatement(node)) {
      return node.elseStatement ? blockHasExit(node.thenStatement) && blockHasExit(node.elseStatement) : false;
    }
    return false;
  }

  function statementRedefines(stmt, name) {
    if (ts.isVariableStatement(stmt)) {
      return stmt.declarationList.declarations.some((d) => ts.isIdentifier(d.name) && d.name.text === name);
    }
    if (ts.isExpressionStatement(stmt) && ts.isBinaryExpression(stmt.expression)) {
      if (stmt.expression.operatorToken.kind === ts.SyntaxKind.EqualsToken && ts.isIdentifier(stmt.expression.left)) {
        return stmt.expression.left.text === name;
      }
    }
    return false;
  }

  function findUsageAfter(statements, startIndex, identifier) {
    const name = identifier.text;
    for (let i = startIndex + 1; i < statements.length; i++) {
      const stmt = statements[i];
      if (statementRedefines(stmt, name)) {
        return null;
      }
      let found = null;
      function search(node) {
        if (found) return;
        if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === name) {
          found = node.expression;
          return;
        }
        if (ts.isPropertyAccessExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === name) {
          found = node.expression;
          return;
        }
        if (ts.isElementAccessExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === name) {
          found = node.expression;
          return;
        }
        ts.forEachChild(node, search);
      }
      search(stmt);
      if (found) return found;
    }
    return null;
  }

  function visit(node) {
    if (ts.isBlock(node)) {
      const statements = node.statements;
      statements.forEach((stmt, idx) => {
        if (ts.isIfStatement(stmt)) {
          const guarded = extractGuardedIdentifier(stmt.expression);
          if (guarded && !stmt.elseStatement && !blockHasExit(stmt.thenStatement)) {
            const usage = findUsageAfter(statements, idx, guarded);
            if (usage) {
              results.push({
                location: formatLocation(filePath, sourceFile, usage.getStart(sourceFile)),
                message: `Value '${guarded.text}' may still be null/undefined after guard`
              });
            }
          }
        }
      });
    }
    ts.forEachChild(node, visit);
  }

  visit(sourceFile);
  return results;
}

async function analyzeFileFallback(filePath) {
  const text = await fs.readFile(filePath, 'utf8');
  const lines = text.split(/\r?\n/);
  const results = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const guard = line.match(/if\s*\(\s*!([A-Za-z_$][\w$]*)\s*\)/) || line.match(/if\s*\(\s*([A-Za-z_$][\w$]*)\s*===\s*(?:null|undefined)\s*\)/);
    if (!guard) continue;
    const name = guard[1];
    let exits = false;
    for (let j = i + 1; j < Math.min(lines.length, i + 6); j++) {
      if (/return\b|throw\b/.test(lines[j])) {
        exits = true;
        break;
      }
    }
    if (exits) continue;
    for (let j = i + 1; j < Math.min(lines.length, i + 25); j++) {
      if (lines[j].includes(name) && /[.([]/.test(lines[j][lines[j].indexOf(name) + name.length] || '')) {
        results.push({
          location: `${filePath}:${j + 1}:1`,
          message: `Value '${name}' checked earlier but used without return (text heuristic)`
        });
        break;
      }
      if (lines[j].includes(`${name} =`)) break;
    }
  }
  return results;
}

async function main() {
  const files = await collectFiles(projectDir);
  let total = 0;
  for (const file of files) {
    const issues = ts ? await analyzeFileWithTs(file) : await analyzeFileFallback(file);
    issues.forEach(({ location, message }) => {
      total++;
      console.log(`${location}\t${message}`);
    });
  }
  if (!ts) {
    console.log('[ubs-type-narrowing] TypeScript compiler not detected');
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
