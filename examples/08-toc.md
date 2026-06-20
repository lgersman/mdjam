---
description: TOC — table of contents block
---

# Table of Contents block

Use a ` ```toc ``` ` fence to render an interactive table of contents.
Tab to focus it, `↑`/`↓` or `j`/`k` to navigate, `Enter` to jump to a heading.

```toc
minDepth: 2
maxDepth: 3
```

---

## Basic usage

Add a `toc` fence anywhere in the document:

````
```toc
```
````

The TOC collects all headings automatically — no manual list to maintain.

---

## Options

All options are optional YAML between the fences:

| Option | Default | Description |
|--------|---------|-------------|
| `title` | *(none)* | Heading shown above the entry list |
| `minDepth` | `1` | Shallowest heading level to include |
| `maxDepth` | `6` | Deepest heading level to include |

Example with all options:

````
```toc
title: "Contents"
minDepth: 2
maxDepth: 3
```
````

---

## Navigation

Focus the TOC with **Tab**, then:

- `↑` / `↓` or `j` / `k` — move selection
- `Enter` — scroll the document to the selected heading
- `Escape` — leave the TOC
- **Tab** again — move to the next focusable block

---

## Constraints

Only one `toc` block per document is rendered. A second one shows a warning.

Headings inside fenced code blocks are intentionally excluded.

### Example of a sub-heading

This heading appears in the TOC above because `minDepth: 2` and `maxDepth: 3` are set,
and this is an `h3`.
