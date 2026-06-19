---
description: Markdown — rendering showcase
---

# Markdown rendering showcase

This document has no executable blocks — it shows how mdrun renders standard markdown.
Scroll with `j`/`k`, jump with `g`/`G`, quit with `q`.

---

## Headings

# H1 — top-level heading
## H2 — section heading
### H3 — subsection
#### H4 — sub-subsection
##### H5 — minor heading
###### H6 — smallest heading

---

## Emphasis and inline formatting

Plain text, **bold text**, *italic text*, ***bold italic***, ~~strikethrough~~, and `inline code`.

Combine them: **`bold code`**, *`italic code`*, **bold and *nested italic* inside**.

---

## Blockquotes

> A single-line blockquote.

> A multi-line blockquote.
> It continues on this line.
>
> And after a blank line too.

> Nested quotes:
> > Inner quote.
> > > Deeper still.

---

## Lists

### Unordered

- First item
- Second item
  - Nested item A
  - Nested item B
    - Doubly nested
- Third item

### Ordered

1. Step one
2. Step two
   1. Sub-step A
   2. Sub-step B
3. Step three

### Task list

- [x] Completed task
- [x] Another done item
- [ ] Pending task
- [ ] Not started yet

---

## Code blocks

A fenced block without a language tag:

```
plain text block
no syntax highlighting
just monospace
```

A shell snippet (display only — no run button):

```sh
#!/usr/bin/env bash
for f in *.md; do
  echo "Found: $f"
done
```

A JavaScript snippet:

```js
function greet(name) {
  return `Hello, ${name}!`;
}
console.log(greet("world"));
```

A Python snippet:

```python
import sys

def fibonacci(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a

print(fibonacci(int(sys.argv[1])))
```

---

## Tables

| Column A  | Column B  | Column C  |
|-----------|-----------|-----------|
| Row 1 A   | Row 1 B   | Row 1 C   |
| Row 2 A   | Row 2 B   | Row 2 C   |
| Row 3 A   | Row 3 B   | Row 3 C   |

Alignment variants:

| Left-aligned | Centered | Right-aligned |
|:-------------|:--------:|--------------:|
| apple        |  banana  |        cherry |
| dog          |   cat    |         mouse |
| 1            |    2     |             3 |

---

## Links and images

An [inline link](https://example.com) and a [link with a title](https://example.com "Example site").

A bare URL: <https://example.com>

An image (falls back to alt text in terminals that don't render images):

![Terminal screenshot placeholder](https://placehold.co/400x200/1e1e2e/cdd6f4?text=mdrun)

---

## Horizontal rules

Three ways to write one — all render the same:

---

***

___

---

## Text with line breaks

Markdown collapses single newlines.
This line follows the one above with no blank line — it flows into the same paragraph.

This is a separate paragraph because there is a blank line above.

---

## Escaped characters

Literal asterisks: \*not italic\*, \*\*not bold\*\*

Literal backtick: \`not code\`

Literal brackets: \[not a link\]

---

## Mixed content

> **Tip:** combine *emphasis* inside blockquotes.
>
> Even a table works here:
>
> | Key | Value |
> |-----|-------|
> | foo | bar   |

A paragraph followed immediately by a list:

- `code` in a list item
- **bold** in a list item
- a [link](https://example.com) in a list item
