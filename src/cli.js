#!/usr/bin/env bun
// @bun

// src/cli.ts
import { parseArgs } from "util";
import { resolve } from "path";
import { existsSync } from "fs";
import"./setup-parsers.js";
import { runApp } from "./app.js";
var HELP = `Usage: mdrun <file> [options]

Terminal markdown viewer with executable code fences

Arguments:
  <file>             Markdown file to open

Options:
  --no-auto          Suppress auto-execution of auto:true blocks
  --no-watch         Disable watch mode (default: enabled)
  --theme <name>     Syntax theme: github-dark | github-light | dracula  (default: github-dark)
  --verbose          Show document frontmatter as a header
  --version          Show version
  --help             Show this help
`;
if (process.argv.length <= 2) {
  process.stdout.write(HELP);
  process.exit(0);
}
var { values, positionals } = parseArgs({
  args: process.argv.slice(2),
  allowPositionals: true,
  options: {
    auto: { type: "boolean", default: true },
    watch: { type: "boolean", default: true },
    theme: { type: "string", default: "github-dark" },
    verbose: { type: "boolean", default: false },
    version: { type: "boolean", default: false },
    help: { type: "boolean", default: false }
  }
});
if (values.help) {
  process.stdout.write(HELP);
  process.exit(0);
}
if (values.version) {
  process.stdout.write(`0.1.0
`);
  process.exit(0);
}
if (positionals.length === 0) {
  process.stderr.write(`Error: missing required argument <file>
`);
  process.exit(1);
}
var filePath = resolve(positionals[0]);
if (!existsSync(filePath)) {
  process.stderr.write(`Error: File not found: ${filePath}
`);
  process.exit(1);
}
var theme = values.theme ?? "github-dark";
var validThemes = ["github-dark", "github-light", "dracula"];
if (!validThemes.includes(theme)) {
  process.stderr.write(`Error: Unknown theme '${theme}'. Valid themes: ${validThemes.join(", ")}
`);
  process.exit(1);
}
await runApp({
  filePath,
  theme,
  noAuto: !values.auto,
  noWatch: !values.watch,
  verbose: values.verbose ?? false
});

//# debugId=E880DE43981942FB64756E2164756E21
//# sourceMappingURL=cli.js.map
