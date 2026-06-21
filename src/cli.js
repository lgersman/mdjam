#!/usr/bin/env bun
// @bun

// src/cli.ts
import { parseArgs } from "util";
import { resolve, dirname, join } from "path";
import { existsSync } from "fs";
import { createRequire } from "module";
import { addDefaultParsers } from "@opentui/core";
import { runApp } from "./app.js";
import pkg from "../package.json";
var _require = createRequire(import.meta.url);
var bashPkgDir = dirname(_require.resolve("tree-sitter-bash/package.json"));
addDefaultParsers([{
  filetype: "bash",
  aliases: ["sh", "shell"],
  wasm: join(bashPkgDir, "tree-sitter-bash.wasm"),
  queries: { highlights: [join(bashPkgDir, "queries/highlights.scm")] }
}]);
var HELP = `Usage: mdrun <file> [options]
       mdrun --stdin [options]

Terminal markdown viewer with executable code fences

Arguments:
  <file>             Markdown file to open

Options:
  --stdin            Read markdown from stdin
  --no-auto          Suppress auto-execution of auto:true blocks
  --no-watch         Disable watch mode (default: enabled)
  --theme <name>     Syntax theme: dark | light | dracula | tokyo-night  (default: dark)
  --verbose          Show document frontmatter as a header
  --delegate         On exit, write the focused block's stdout/stderr and use its exit code
  --agent-docs       Print agent-optimised reference and exit
  --version          Show version
  --help             Show this help
`;
var AGENT_DOCS = `mdrun \u2014 execute bash code fences in a markdown document

USAGE (non-interactive / agent):
  printf '%s' "$MARKDOWN" | mdrun --stdin --delegate --no-watch
  mdrun --delegate --no-watch <file.md>

FLAGS FOR AGENTS:
  --stdin        Read markdown from stdin (watch disabled automatically)
  --delegate     On exit: forward focused block stdout\u2192stdout, stderr\u2192stderr, mirror exit code
  --no-auto      Suppress auto:true blocks
  --no-watch     Disable file reload; always set for non-interactive use

EXIT CODES:
  0    Success (or --delegate: block exited 0)
  1    Bad args / file not found / prerequisite or setup script failed
  -1   --delegate: selected block was not executed

AUTO-EXECUTION:
  Blocks marked auto:true run on load without keypresses.
  mdrun exits when all auto blocks have finished and no interactive inputs are pending.

BLOCK METADATA (YAML comment header inside a bash fence):
  \`\`\`bash
  # ---
  # id: step1
  # auto: true
  # outputs: [RESULT]
  # ---
  echo "::set-output name=RESULT::$(compute_something)"
  \`\`\`

OUTPUT PROTOCOL:
  echo "::set-output name=KEY::value"   # silent capture into state store
  export KEY=value                      # exported vars also captured into state store

DOWNSTREAM BLOCKS receive state store values as MDFENCE_<KEY> environment variables.

EXAMPLE \u2014 pipe generated markdown, capture result:
  md=$(cat <<'EOF'
  \`\`\`bash
  # ---
  # auto: true
  # outputs: [STATUS]
  # ---
  export STATUS=done
  \`\`\`
  EOF
  )
  result=$(printf '%s' "$md" | mdrun --stdin --delegate --no-watch)
  echo "exit=$? result=$result"
`;
if (process.argv.length <= 2) {
  process.stdout.write(HELP);
  process.exit(0);
}
var { values, positionals } = parseArgs({
  args: process.argv.slice(2),
  allowPositionals: true,
  options: {
    stdin: { type: "boolean", default: false },
    auto: { type: "boolean", default: true },
    watch: { type: "boolean", default: true },
    theme: { type: "string", default: "dark" },
    verbose: { type: "boolean", default: false },
    delegate: { type: "boolean", default: false },
    "agent-docs": { type: "boolean", default: false },
    version: { type: "boolean", default: false },
    help: { type: "boolean", default: false }
  }
});
if (values.help) {
  process.stdout.write(HELP);
  process.exit(0);
}
if (values["agent-docs"]) {
  process.stdout.write(AGENT_DOCS);
  process.exit(0);
}
if (values.version) {
  process.stdout.write(`${pkg.version}
`);
  process.exit(0);
}
var theme = values.theme ?? "dark";
var validThemes = ["dark", "light", "dracula", "tokyo-night"];
if (!validThemes.includes(theme)) {
  process.stderr.write(`Error: Unknown theme '${theme}'. Valid themes: ${validThemes.join(" | ")}
`);
  process.exit(1);
}
if (values.stdin) {
  const content = await Bun.stdin.text();
  await runApp({
    content,
    theme,
    noAuto: !values.auto,
    noWatch: true,
    verbose: values.verbose ?? false,
    delegate: values.delegate ?? false
  });
} else {
  if (positionals.length === 0) {
    process.stderr.write(`Error: missing required argument <file>
`);
    process.exit(1);
  }
  const filePath = resolve(positionals[0]);
  if (!existsSync(filePath)) {
    process.stderr.write(`Error: File not found: ${filePath}
`);
    process.exit(1);
  }
  await runApp({
    filePath,
    theme,
    noAuto: !values.auto,
    noWatch: !values.watch,
    verbose: values.verbose ?? false,
    delegate: values.delegate ?? false
  });
}

//# debugId=237E84D0A4932BFD64756E2164756E21
//# sourceMappingURL=cli.js.map
