#!/usr/bin/env node
import { Command as J } from "commander";
import { join as U, resolve as Q } from "node:path";
import { readFileSync as $, unlinkSync as G, watch as ee, existsSync as te } from "node:fs";
import { SyntaxStyle as ne, BoxRenderable as w, TextRenderable as h, InputRenderable as se, InputRenderableEvents as re, CodeRenderable as ie, createCliRenderer as oe, ScrollBoxRenderable as ae, createMarkdownCodeBlockRenderer as ce, MarkdownRenderable as le } from "@opentui/core";
import ue from "gray-matter";
import de from "js-yaml";
import { EventEmitter as T } from "node:events";
import { spawn as j, execSync as fe } from "node:child_process";
import { tmpdir as V } from "node:os";
function he(i) {
  try {
    const e = ue(i);
    return {
      frontmatter: e.data ?? {},
      body: e.content
    };
  } catch {
    return { frontmatter: {}, body: i };
  }
}
const pe = /^# ---\n((?:#[^\n]*\n)*)# ---\n/;
function z(i) {
  const e = i.match(pe);
  if (!e)
    return { metadata: null, cleanBody: i };
  const t = e[1].split(`
`).map((s) => s.replace(/^#[ ]?/, "")).join(`
`), n = i.slice(e[0].length);
  try {
    const s = de.load(t);
    return s === null || typeof s != "object" ? { metadata: null, cleanBody: n } : { metadata: s, cleanBody: n };
  } catch (s) {
    return {
      metadata: null,
      cleanBody: n,
      parseError: s instanceof Error ? s.message : String(s)
    };
  }
}
function ge(i) {
  const e = [], t = /^```(?:bash|sh)\n([\s\S]*?)^```/gm;
  let n = 0, s;
  for (; (s = t.exec(i)) !== null; ) {
    const r = s[1], { metadata: c } = z(r), o = c?.id ?? `__fence_${n}`, d = c?.depends ?? [];
    e.push({ id: o, depends: d }), n++;
  }
  return e;
}
function be(i) {
  const e = new Map(i.map((o) => [o.id, o])), t = /* @__PURE__ */ new Set(), n = /* @__PURE__ */ new Set(), s = [], r = /* @__PURE__ */ new Map();
  function c(o, d) {
    if (n.has(o)) {
      const l = d.indexOf(o), a = d.slice(l);
      for (const u of a)
        r.has(u) || r.set(u, a);
      return;
    }
    if (t.has(o)) return;
    n.add(o);
    const p = e.get(o);
    if (p)
      for (const l of p.depends)
        c(l, [...d, o]);
    n.delete(o), t.add(o), s.push(o);
  }
  for (const o of i)
    t.has(o.id) || c(o.id, []);
  return { executionOrder: s, cyclesByBlock: r };
}
function me(i, e, t) {
  const n = /* @__PURE__ */ new Set();
  function s(r) {
    if (!n.has(r)) {
      n.add(r);
      for (const c of e.get(r) ?? [])
        s(c);
    }
  }
  return s(i), t.executionOrder.filter((r) => n.has(r));
}
class R extends T {
  store = /* @__PURE__ */ new Map();
  set(e, t, n = null) {
    this.store.set(e, { value: t, sourceBlock: n }), this.emit("change", e, t, n);
  }
  get(e) {
    return this.store.get(e)?.value;
  }
  getEntry(e) {
    return this.store.get(e);
  }
  has(e) {
    return this.store.has(e);
  }
  entries() {
    return this.store.entries();
  }
  size() {
    return this.store.size;
  }
  clear() {
    this.store.clear(), this.emit("reset");
  }
  /** Build MDFENCE_<KEY>=<VALUE> environment object from store contents. */
  toEnv() {
    const e = {};
    for (const [t, n] of this.store)
      e[`MDFENCE_${t.toUpperCase()}`] = n.value;
    return e;
  }
}
const xe = /^::set-output name=([^:]+)::(.*)$/;
class we extends T {
  blockId;
  status = "idle";
  exitCode = null;
  proc = null;
  stateStore;
  constructor(e, t) {
    super(), this.blockId = e, this.stateStore = t;
  }
  async run(e) {
    this.cancelInternal(), this.setStatus("running");
    const t = U(V(), `mdrun_${this.blockId.replace(/[^a-z0-9]/gi, "_")}_${process.pid}.env`), n = [
      `_MDRUN_CAP="${t}"`,
      `trap 'export -p > "$_MDRUN_CAP" 2>/dev/null || true' EXIT`,
      e
    ].join(`
`), s = { ...process.env }, r = {
      ...s,
      ...this.stateStore.toEnv()
    };
    this.proc = j("/bin/bash", ["-c", n], {
      env: r,
      stdio: ["ignore", "pipe", "pipe"]
    });
    const c = (d, p) => {
      if (!p) {
        const l = d.match(xe);
        if (l) {
          const [, a, u] = l;
          this.stateStore.set(a, u, this.blockId), this.stateStore.set(`${this.blockId}.${a}`, u, this.blockId), this.emit("setOutput", a, u);
          return;
        }
      }
      this.emit("output", d + `
`);
    }, o = (d, p) => {
      let l = "";
      d.on("data", (a) => {
        l += a.toString();
        const u = l.split(`
`);
        l = u.pop() ?? "";
        for (const x of u) c(x, p);
      }), d.on("end", () => {
        l.length > 0 && c(l, p);
      });
    };
    return this.proc.stdout && o(this.proc.stdout, !1), this.proc.stderr && o(this.proc.stderr, !0), new Promise((d) => {
      this.proc.on("close", (p, l) => {
        const a = p ?? (l ? 1 : 0);
        try {
          const u = $(t, "utf8");
          this.captureExports(u, s);
        } catch {
        }
        try {
          G(t);
        } catch {
        }
        this.status !== "cancelled" && (this.exitCode = a, this.setStatus(a === 0 ? "success" : "failed", a)), this.proc = null, this.emit("done", a), d(a);
      });
    });
  }
  cancel() {
    this.cancelInternal();
  }
  cancelInternal() {
    if (!this.proc) return;
    this.setStatus("cancelled");
    const e = this.proc;
    this.proc = null, e.kill("SIGTERM"), setTimeout(() => {
      try {
        e.kill("SIGKILL");
      } catch {
      }
    }, 3e3);
  }
  captureExports(e, t) {
    for (const n of e.split(`
`)) {
      const s = n.match(/^declare -x ([A-Za-z_][A-Za-z0-9_]*)(?:="((?:[^"\\]|\\.)*)")?$/);
      if (!s) continue;
      const r = s[1], c = s[2] ?? "";
      r in t || r.startsWith("MDFENCE_") || r === "_MDRUN_CAP" || (this.stateStore.set(r, c, this.blockId), this.stateStore.set(`${this.blockId}.${r}`, c, this.blockId));
    }
  }
  setStatus(e, t) {
    this.status = e, t !== void 0 && (this.exitCode = t), this.emit("status", e, t);
  }
}
const Se = /^::set-output name=([^:]+)::(.*)$/;
class L extends T {
  constructor(e) {
    super(), this.stateStore = e;
  }
  async runSetup(e) {
    return this.runScript("setup", e);
  }
  async runTeardown(e) {
    return this.runScript("teardown", e);
  }
  async runScript(e, t) {
    const n = U(V(), `mdrun_${e}_${process.pid}.env`), s = [
      `_MDRUN_CAP="${n}"`,
      `trap 'export -p > "$_MDRUN_CAP" 2>/dev/null || true' EXIT`,
      t
    ].join(`
`), r = { ...process.env }, c = {
      ...r,
      ...this.stateStore.toEnv()
    }, o = j("/bin/bash", ["-c", s], {
      env: c,
      stdio: ["ignore", "pipe", "pipe"]
    });
    let d = "";
    const p = (a) => {
      const u = a.match(Se);
      if (u) {
        const [, x, S] = u;
        this.stateStore.set(x, S, null);
        return;
      }
      this.emit("output", a + `
`);
    }, l = (a) => {
      a.on("data", (u) => {
        d += u.toString();
        const x = d.split(`
`);
        d = x.pop() ?? "";
        for (const S of x) p(S);
      }), a.on("end", () => {
        d.length > 0 && p(d), d = "";
      });
    };
    return o.stdout && l(o.stdout), o.stderr && l(o.stderr), new Promise((a) => {
      o.on("close", (u) => {
        const x = u ?? 1;
        try {
          const S = $(n, "utf8");
          this.captureExports(S, r);
        } catch {
        }
        try {
          G(n);
        } catch {
        }
        this.emit("done", x), a(x);
      });
    });
  }
  captureExports(e, t) {
    for (const n of e.split(`
`)) {
      const s = n.match(/^declare -x ([A-Za-z_][A-Za-z0-9_]*)(?:="((?:[^"\\]|\\.)*)")?$/);
      if (!s) continue;
      const r = s[1], c = s[2] ?? "";
      r in t || r.startsWith("MDFENCE_") || r === "_MDRUN_CAP" || this.stateStore.set(r, c, null);
    }
  }
}
class ke {
  constructor(e, t, n) {
    this.stateStore = e, this.graph = t, this.allBlocks = n;
  }
  successfulBlocks = /* @__PURE__ */ new Set();
  failedBlocks = /* @__PURE__ */ new Set();
  /** Execute a block, first resolving and running any unrun dependencies. */
  async execute(e) {
    if (this.graph.cyclesByBlock.has(e.id))
      return !1;
    const t = new Map(
      Array.from(this.allBlocks.values()).map((s) => [s.id, s.depends])
    ), n = me(e.id, t, this.graph);
    for (const s of n)
      if (s !== e.id) {
        if (this.failedBlocks.has(s))
          return e.runner.emit("status", "dep-failed"), !1;
        if (!this.successfulBlocks.has(s)) {
          const r = this.allBlocks.get(s);
          if (!r) continue;
          if (!await this.runBlock(r))
            return e.runner.emit("status", "dep-failed"), !1;
        }
      }
    return this.runBlock(e);
  }
  async runBlock(e) {
    if (this.successfulBlocks.has(e.id)) return !0;
    const n = await e.runner.run(e.script) === 0;
    return n ? this.successfulBlocks.add(e.id) : this.failedBlocks.add(e.id), n;
  }
  reset() {
    this.successfulBlocks.clear(), this.failedBlocks.clear();
  }
  registerBlock(e) {
    this.allBlocks.set(e.id, e);
  }
}
function ye(i) {
  try {
    return fe(`command -v ${i}`, { stdio: "ignore" }), !0;
  } catch {
    return !1;
  }
}
async function ve(i) {
  const e = [], t = [];
  for (const n of i.tools ?? [])
    ye(n) ? e.push(`tool:${n}`) : t.push(`tool '${n}' not found in PATH`);
  for (const n of i.env ?? [])
    process.env[n] !== void 0 ? e.push(`env:${n}`) : t.push(`env var $${n} is not set`);
  return { passed: e, failed: t };
}
const H = {
  keyword: { fg: "#ff7b72", bold: !0 },
  string: { fg: "#a5d6ff" },
  number: { fg: "#79c0ff" },
  comment: { fg: "#8b949e", italic: !0 },
  function: { fg: "#d2a8ff" },
  variable: { fg: "#ffa657" },
  type: { fg: "#79c0ff" },
  operator: { fg: "#ff7b72" },
  punctuation: { fg: "#c9d1d9" },
  constant: { fg: "#79c0ff" },
  property: { fg: "#ffa657" },
  tag: { fg: "#7ee787" },
  attribute: { fg: "#a5d6ff" },
  "string.special": { fg: "#a5d6ff" },
  plain: { fg: "#c9d1d9" },
  conceal: { fg: "#8b949e" }
}, Be = {
  keyword: { fg: "#cf222e", bold: !0 },
  string: { fg: "#0a3069" },
  number: { fg: "#0550ae" },
  comment: { fg: "#6e7781", italic: !0 },
  function: { fg: "#8250df" },
  variable: { fg: "#953800" },
  type: { fg: "#0550ae" },
  operator: { fg: "#cf222e" },
  punctuation: { fg: "#24292f" },
  constant: { fg: "#0550ae" },
  property: { fg: "#953800" },
  tag: { fg: "#116329" },
  attribute: { fg: "#0a3069" },
  "string.special": { fg: "#0a3069" },
  plain: { fg: "#24292f" },
  conceal: { fg: "#6e7781" }
}, Ee = {
  keyword: { fg: "#ff79c6", bold: !0 },
  string: { fg: "#f1fa8c" },
  number: { fg: "#bd93f9" },
  comment: { fg: "#6272a4", italic: !0 },
  function: { fg: "#50fa7b" },
  variable: { fg: "#ffb86c" },
  type: { fg: "#8be9fd" },
  operator: { fg: "#ff79c6" },
  punctuation: { fg: "#f8f8f2" },
  constant: { fg: "#bd93f9" },
  property: { fg: "#ffb86c" },
  tag: { fg: "#50fa7b" },
  attribute: { fg: "#50fa7b" },
  "string.special": { fg: "#f1fa8c" },
  plain: { fg: "#f8f8f2" },
  conceal: { fg: "#6272a4" }
}, Ce = {
  "github-dark": H,
  "github-light": Be,
  dracula: Ee
};
function Ie(i) {
  const e = Ce[i] ?? H;
  return ne.fromStyles(e);
}
class Re extends w {
  name;
  valueInput = null;
  valueDisplay = null;
  sourceLabel;
  spec;
  stateStore;
  constructor(e, t) {
    super(e, {
      flexDirection: "row",
      flexShrink: 0,
      paddingLeft: 2,
      marginBottom: 0
    }), this.name = t.name, this.spec = t.spec, this.stateStore = t.stateStore, this.add(new h(e, {
      content: `  ${t.name}: `,
      fg: "#8b949e",
      flexShrink: 0
    }));
    const n = this.stateStore.get(t.name) ?? t.spec.default ?? "", s = this.resolveSource(t.name);
    if (t.spec.readonly ? (this.valueDisplay = new h(e, {
      content: n,
      fg: "#a5d6ff",
      flexGrow: 1
    }), this.add(this.valueDisplay)) : (this.valueInput = new se(e, {
      value: n,
      textColor: "#f0f0f0",
      flexGrow: 1
    }), this.valueInput.focusable = !0, this.valueInput.on(re.CHANGE, (r) => {
      this.stateStore.set(t.name, r, null);
    }), this.add(this.valueInput)), this.sourceLabel = new h(e, {
      content: s ? ` [${s}]` : "",
      fg: "#6e7781",
      flexShrink: 0
    }), this.add(this.sourceLabel), t.spec.description) {
      const r = new w(e, {
        flexDirection: "row",
        paddingLeft: 4
      });
      r.add(new h(e, {
        content: t.spec.description,
        fg: "#6e7781",
        italic: !0
      })), this.add(r);
    }
    this.stateStore.on("change", (r, c, o) => {
      r === t.name && this.updateValue(c, o ? `block:${o}` : "setup");
    });
  }
  get currentValue() {
    if (this.valueInput) return this.valueInput.value;
    if (this.valueDisplay) {
      const e = this.valueDisplay.content;
      return typeof e == "string" ? e : "";
    }
    return this.spec.default ?? "";
  }
  hasValue() {
    return this.currentValue.length > 0;
  }
  updateValue(e, t) {
    this.valueInput ? this.valueInput.value = e : this.valueDisplay && (this.valueDisplay.content = e), this.sourceLabel.content = ` [${t}]`;
  }
  resolveSource(e) {
    const t = this.stateStore.getEntry(e);
    return t ? t.sourceBlock === null ? "setup" : `block:${t.sourceBlock}` : null;
  }
}
class $e extends w {
  rows = [];
  constructor(e, t, n) {
    if (super(e, {
      flexDirection: "column",
      flexShrink: 0,
      marginBottom: 0
    }), !!t.inputs)
      for (const [s, r] of Object.entries(t.inputs)) {
        const c = new Re(e, { name: s, spec: r, stateStore: n });
        this.rows.push(c), this.add(c);
      }
  }
  /** Returns true if all required inputs (no default, not set) have a value. */
  allInputsSatisfied() {
    return this.rows.every((e) => e.hasValue());
  }
  /** Returns names of inputs that have no value. */
  missingInputs() {
    return this.rows.filter((e) => !e.hasValue()).map((e) => e.name);
  }
  /** Returns the current values as key→value map. */
  inputValues() {
    const e = {};
    for (const t of this.rows)
      e[t.name] = t.currentValue;
    return e;
  }
  get focusableInputs() {
    return this.rows.filter((e) => !e.getChildren().every((t) => t._focusable === !1));
  }
}
const Te = {
  idle: { icon: "○", fg: "#8b949e", label: "Ready" },
  running: { icon: "⟳", fg: "#f0a030", label: "Running…" },
  success: { icon: "✓", fg: "#3fb950", label: "Done" },
  failed: { icon: "✗", fg: "#f85149", label: "Failed" },
  cancelled: { icon: "◌", fg: "#8b949e", label: "Cancelled" },
  blocked: { icon: "✗", fg: "#f85149", label: "Blocked" },
  "dep-failed": { icon: "✗", fg: "#f85149", label: "Skipped — dep failed" }
};
class Pe extends w {
  statusText;
  hintText;
  constructor(e) {
    super(e, {
      flexDirection: "row",
      flexShrink: 0,
      paddingLeft: 2,
      paddingTop: 0,
      paddingBottom: 0
    }), this.statusText = new h(e, {
      content: "○ Ready",
      fg: "#8b949e",
      flexGrow: 1
    }), this.add(this.statusText), this.hintText = new h(e, {
      content: "  [Enter] Run",
      fg: "#6e7781",
      flexShrink: 0
    }), this.add(this.hintText);
  }
  update(e, t, n) {
    const s = Te[e];
    let r = s.label;
    e === "success" && t !== void 0 && t !== null ? r = `Done (exit ${t})` : e === "failed" && t !== void 0 && t !== null ? r = `Failed (exit ${t})` : e === "blocked" && n?.length && (r = `Blocked — missing: ${n.join(", ")}`), this.statusText.content = `${s.icon} ${r}`, this.statusText.fg = s.fg, e === "running" ? this.hintText.content = "  [Esc] Cancel" : e === "blocked" ? this.hintText.content = "" : this.hintText.content = "  [Enter] Run";
  }
  setFocused(e) {
    this.hintText.fg = e ? "#58a6ff" : "#6e7781";
  }
}
const O = 1e4;
class _e extends w {
  textRenderable;
  lineCount = 0;
  truncated = !1;
  collapsed = !1;
  constructor(e, t = {}) {
    super(e, {
      flexDirection: "column",
      flexShrink: 0,
      paddingLeft: 2,
      ...t
    }), this.textRenderable = new h(e, {
      content: "",
      flexShrink: 0
    }), this.add(this.textRenderable), this.visible = !1;
  }
  append(e) {
    if (this.truncated) return;
    const t = e.split(`
`).length - 1;
    if (this.lineCount += t, this.lineCount > O) {
      this.truncated = !0;
      const s = typeof this.textRenderable.content == "string" ? this.textRenderable.content : "";
      this.textRenderable.content = s + `
[output truncated at ${O} lines]`;
      return;
    }
    const n = typeof this.textRenderable.content == "string" ? this.textRenderable.content : "";
    this.textRenderable.content = n + e, this.visible = !0;
  }
  clear() {
    this.textRenderable.content = "", this.lineCount = 0, this.truncated = !1, this.visible = !1;
  }
  toggle() {
    this.collapsed = !this.collapsed, !this.collapsed && this.lineCount > 0 ? this.visible = !0 : this.visible = this.collapsed ? !1 : this.lineCount > 0;
  }
}
class F extends w {
  inputPanel = null;
  statusBar;
  outputPanel;
  runner;
  options;
  constructor(e, t) {
    if (super(e, {
      flexDirection: "column",
      flexShrink: 0,
      marginBottom: 1,
      border: !0,
      borderColor: "#30363d",
      focusedBorderColor: "#58a6ff",
      focusable: !0
    }), this.runner = t.runner, this.options = t, t.parseError ? this.add(new h(e, {
      content: `⚠ Metadata parse error: ${t.parseError}`,
      fg: "#f85149",
      flexShrink: 0,
      paddingLeft: 1
    })) : t.metadata?.description && this.add(new h(e, {
      content: `  ${t.metadata.description}`,
      fg: "#8b949e",
      italic: !0,
      flexShrink: 0
    })), t.metadata?.id && t.metadata.depends?.length, t.metadata?.inputs && Object.keys(t.metadata.inputs).length > 0 && (this.inputPanel = new $e(e, t.metadata, t.stateStore), this.add(this.inputPanel)), this.add(new ie(e, {
      content: t.cleanBody.trimEnd(),
      filetype: "bash",
      syntaxStyle: t.syntaxStyle,
      conceal: !1,
      flexShrink: 0,
      paddingLeft: 2
    })), this.statusBar = new Pe(e), this.add(this.statusBar), this.outputPanel = new _e(e), this.add(this.outputPanel), this.runner.on("status", (n, s) => {
      const r = this.inputPanel?.missingInputs();
      this.statusBar.update(n, s, r);
    }), this.runner.on("output", (n) => {
      this.outputPanel.append(n);
    }), t.executionBlocked)
      this.statusBar.update("blocked");
    else if (this.inputPanel && !this.inputPanel.allInputsSatisfied()) {
      const n = this.inputPanel.missingInputs();
      this.statusBar.update("blocked", null, n);
    } else
      this.statusBar.update("idle");
    this.inputPanel && t.stateStore.on("change", () => {
      !t.executionBlocked && this.runner.status === "blocked" && this.inputPanel.allInputsSatisfied() && (this.statusBar.update("idle"), this.runner.emit("status", "idle"));
    });
  }
  handleKeyPress(e) {
    return e.name === "return" || e.name === "enter" ? (this.options.executionBlocked || this.inputPanel && !this.inputPanel.allInputsSatisfied() || this.runner.status === "running" || (this.outputPanel.clear(), this.options.onExecute().catch(() => {
    })), !0) : e.name === "escape" ? (this.runner.status === "running" && this.runner.cancel(), !0) : !1;
  }
  propagateFocusChange(e) {
    super.propagateFocusChange(e), this.statusBar.setFocused(e), e ? this.borderColor = "#58a6ff" : this.borderColor = "#30363d";
  }
  get blockId() {
    return this.runner.blockId;
  }
  get depends() {
    return this.options.metadata?.depends ?? [];
  }
  get script() {
    return this.options.cleanBody;
  }
  get metadata() {
    return this.options.metadata;
  }
  get isAutoExecute() {
    return this.options.metadata?.auto === !0;
  }
  get isExecutionBlocked() {
    return this.options.executionBlocked;
  }
}
class De extends w {
  constructor(e, t) {
    super(e, {
      flexDirection: "column",
      flexShrink: 0,
      border: !0,
      borderColor: "#f85149",
      marginBottom: 1
    }), this.add(new h(e, {
      content: "  Prerequisites failed — code fence execution is disabled",
      fg: "#f85149",
      bold: !0,
      flexShrink: 0
    }));
    for (const n of t.failed)
      this.add(new h(e, {
        content: `  ✗ ${n}`,
        fg: "#ffa657",
        flexShrink: 0
      }));
  }
}
class N extends w {
  rendererCtx;
  constructor(e, t) {
    super(e, {
      flexDirection: "column",
      flexShrink: 0,
      border: !0,
      borderColor: "#f85149",
      marginBottom: 1
    }), this.rendererCtx = e, this.add(new h(e, {
      content: `  Setup script failed (exit ${t}) — code fence execution is disabled`,
      fg: "#f85149",
      bold: !0,
      flexShrink: 0
    }));
  }
  appendOutput(e) {
    this.add(new h(this.rendererCtx, {
      content: `  ${e}`,
      fg: "#ffa657",
      flexShrink: 0
    }));
  }
}
class Me extends w {
  contentBox;
  stateStore;
  renderCtx;
  constructor(e, t) {
    super(e, {
      position: "absolute",
      right: 0,
      top: 0,
      width: 60,
      height: "100%",
      flexDirection: "column",
      border: !0,
      borderColor: "#30363d",
      backgroundColor: "#0d1117",
      zIndex: 100,
      visible: !1
    }), this.stateStore = t, this.renderCtx = e, this.add(new h(e, {
      content: " State Store  [s] to close",
      fg: "#c9d1d9",
      bold: !0,
      flexShrink: 0,
      paddingBottom: 1
    })), this.contentBox = new w(e, {
      flexDirection: "column",
      flexGrow: 1
    }), this.add(this.contentBox), t.on("change", () => this.refresh()), t.on("reset", () => this.refresh());
  }
  setStore(e) {
    this.stateStore = e, e.on("change", () => {
      this.visible && this.refresh();
    }), e.on("reset", () => {
      this.visible && this.refresh();
    }), this.visible && this.refresh();
  }
  toggle() {
    this.visible = !this.visible, this.visible && this.refresh();
  }
  refresh() {
    for (const e of this.contentBox.getChildren())
      this.contentBox.remove(e.id);
    if (this.stateStore.size() === 0) {
      this.contentBox.add(new h(this.renderCtx, {
        content: "  (empty)",
        fg: "#6e7781"
      }));
      return;
    }
    for (const [e, t] of this.stateStore.entries()) {
      const n = t.sourceBlock === null ? "setup" : `block:${t.sourceBlock}`, s = new h(this.renderCtx, {
        content: `  ${e} = ${t.value}  [${n}]`,
        fg: "#a5d6ff",
        flexShrink: 0
      });
      this.contentBox.add(s);
    }
  }
}
class Ae extends w {
  renderCtx;
  constructor(e) {
    super(e, {
      flexDirection: "column",
      flexShrink: 0,
      border: !0,
      borderColor: "#30363d",
      visible: !1
    }), this.renderCtx = e, this.add(new h(e, {
      content: "  Teardown",
      fg: "#8b949e",
      flexShrink: 0
    }));
  }
  appendOutput(e) {
    this.add(new h(this.renderCtx, {
      content: `  ${e}`,
      fg: "#c9d1d9",
      flexShrink: 0
    })), this.visible = !0;
  }
}
async function Le(i) {
  const e = await oe({
    exitOnCtrlC: !1,
    exitSignals: [],
    autoFocus: !0
  }), t = Ie(i.theme), n = new w(e, {
    flexDirection: "column",
    width: "100%",
    height: "100%"
  });
  e.root.add(n);
  const s = new ae(e, {
    flexGrow: 1,
    width: "100%",
    scrollY: !0,
    scrollX: !1
  });
  n.add(s);
  const r = new Me(e, new R());
  e.root.add(r);
  const c = new Ae(e);
  n.add(c);
  let o = [], d, p = null, l = new R(), a = null, u = /* @__PURE__ */ new Map();
  async function x() {
    if (o.forEach((f) => {
      try {
        f.destroyRecursively();
      } catch {
      }
    }), o = [], u = /* @__PURE__ */ new Map(), l.clear(), p) {
      try {
        p.destroyRecursively();
      } catch {
      }
      p = null;
    }
    for (const f of s.content.getChildren())
      s.content.remove(f.id);
    let g;
    try {
      g = $(i.filePath, "utf8");
    } catch (f) {
      const m = new w(e, { flexDirection: "column", padding: 1 });
      m.add(new h(e, {
        content: `Error reading file: ${f instanceof Error ? f.message : String(f)}`,
        fg: "#f85149"
      })), s.content.add(m);
      return;
    }
    const { frontmatter: b, body: E } = he(g);
    d = b.teardown, l = new R(), r.setStore(l);
    for (const [f, m] of Object.entries(b.defaults ?? {}))
      l.set(f, m, null);
    const _ = await ve(b.prerequisites ?? {});
    let y = _.failed.length > 0;
    if (y) {
      const f = new De(e, _);
      s.content.add(f);
    }
    if (!y && b.setup) {
      const f = new L(l), m = new N(e, 0);
      f.on("output", (v) => {
        m.appendOutput(v);
      });
      const k = await f.runSetup(b.setup);
      if (k !== 0) {
        const v = new N(e, k);
        f.removeAllListeners("output"), s.content.add(v), y = !0;
      }
    }
    const K = ge(E), W = be(K);
    u = /* @__PURE__ */ new Map(), a = new ke(l, W, u);
    let X = 0;
    const D = (f) => {
      const { metadata: m, cleanBody: k, parseError: v } = z(f.text), B = m?.id ?? `__fence_${X++}`, I = new we(B, l), M = new F(e, {
        token: f,
        cleanBody: k,
        metadata: m,
        parseError: v,
        runner: I,
        stateStore: l,
        syntaxStyle: t,
        executionBlocked: y,
        onExecute: async () => {
          const A = {
            id: B,
            depends: m?.depends ?? [],
            runner: I,
            script: k
          };
          u.set(B, A), a && await a.execute(A);
        }
      });
      o.push(M);
      const Y = {
        id: B,
        depends: m?.depends ?? [],
        runner: I,
        script: k
      };
      return u.set(B, Y), M;
    }, Z = ce({
      bash: D,
      sh: D
    });
    if (p = new le(e, {
      content: E,
      syntaxStyle: t,
      renderNode: Z,
      conceal: !0,
      flexShrink: 0,
      width: "100%"
    }), s.content.add(p), !i.noAuto && !y) {
      for (const f of o)
        if (f.isAutoExecute) {
          const m = u.get(f.blockId);
          m && a && a.execute(m).catch(() => {
          });
        }
    }
  }
  await x();
  let S = -1;
  function P(g) {
    const b = o.filter((E) => !E.isExecutionBlocked);
    b.length !== 0 && (S = (S + g + b.length) % b.length, e.focusRenderable(b[S]));
  }
  e.keyInput.on("keypress", async (g) => {
    const b = e.currentFocusedRenderable;
    if (!(b && !(b instanceof F)))
      switch (g.name) {
        case "q":
          await C();
          break;
        case "r":
          S = -1, await x();
          break;
        case "s":
          r.toggle();
          break;
        case "j":
        case "down":
          s.scrollBy(3);
          break;
        case "k":
        case "up":
          s.scrollBy(-3);
          break;
        case "space":
        case "pagedown":
          s.scrollBy(e.height - 2);
          break;
        case "b":
        case "pageup":
          s.scrollBy(-(e.height - 2));
          break;
        case "g":
          g.shift || s.scrollTo(0);
          break;
        case "G":
          s.scrollTo({ x: 0, y: s.scrollHeight });
          break;
        case "tab":
          g.preventDefault(), g.shift ? P(-1) : P(1);
          break;
      }
  });
  async function C() {
    if (d) {
      const g = new L(l);
      g.on("output", (b) => {
        c.appendOutput(b), c.visible = !0;
      }), await g.runTeardown(d);
    }
    e.destroy(), process.exit(0);
  }
  if (process.on("SIGINT", async () => {
    await C();
  }), process.on("SIGTERM", async () => {
    await C();
  }), !i.noWatch) {
    let g = null;
    try {
      ee(i.filePath, () => {
        g && clearTimeout(g), g = setTimeout(async () => {
          S = -1, await x(), g = null;
        }, 200);
      });
    } catch {
    }
  }
}
const q = new J();
q.name("mdrun").description("Terminal markdown viewer with executable code fences").version("0.1.0").argument("<file>", "Markdown file to open").option("--no-auto", "Suppress auto-execution of auto:true blocks").option("--no-watch", "Disable watch mode (default: watch enabled)").option("--watch", "Reload document on file change (default)").option(
  "--theme <name>",
  "Syntax theme: github-dark | github-light | dracula",
  "github-dark"
).action(async (i, e) => {
  const t = Q(process.cwd(), i);
  te(t) || (console.error(`Error: File not found: ${t}`), process.exit(1));
  const n = e.theme ?? "github-dark", s = ["github-dark", "github-light", "dracula"];
  s.includes(n) || (console.error(`Error: Unknown theme '${n}'. Valid themes: ${s.join(", ")}`), process.exit(1)), await Le({
    filePath: t,
    theme: n,
    noAuto: !e.auto,
    noWatch: !e.watch
  });
});
q.parse();
//# sourceMappingURL=cli.js.map
