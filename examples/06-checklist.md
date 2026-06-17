---
title: Release checklist
---

# Release checklist

A worked example of task lists rendered with `[✓]` and `[ ]` markers.

---

## Pre-release

### Code

- [x] All tests passing
- [x] Linter clean (`npm run lint`)
- [x] TypeScript compiles without errors
- [ ] Code review approved
- [ ] Changelog updated

### Documentation

- [x] README reflects current CLI flags
- [x] Examples directory up to date
- [ ] API docs regenerated
- [ ] Migration guide written (if breaking changes)

---

## Release

- [ ] Version bumped in `package.json`
- [ ] Git tag created (`git tag vX.Y.Z`)
- [ ] Published to npm (`npm publish`)
- [ ] GitHub release created with release notes

---

## Post-release

- [ ] Announcement posted
- [ ] Issues closed / milestones resolved
- [ ] Next milestone opened

---

## Notes

Task lists mix naturally with other markdown:

> Items marked `[✓]` are done; `[ ]` items are still pending.

Inline code, **bold**, and *italic* all work inside task items too:

- [x] Enable **GFM** (`gfm: true`) in the parser
- [x] Strip `[x]`/`[ ]` prefix — replace with `[✓]`/`[ ]` marker
- [ ] Add *strikethrough* style on completed items
