---
name: feedback-repo-conventions
description: Keep all memories and Claude-related scripts inside the parcours-et-pistes repo under .claude/, version them with git, commit often
metadata:
  type: feedback
---

All memories and Claude-related scripts/config live in the repo
(`/home/pmp/devel/parcours-et-pistes/.claude/`: `memory/`, `scripts/`, `settings.json`).
`~/.claude/projects/-home-pmp-devel-parcours-et-pistes/memory` is a symlink to `.claude/memory`.
Everything is handled with git, and we **commit often**.

**Why:** the user wants the project's Claude context versioned and shareable with the repo, not hidden in ~/.claude.

**How to apply:** write new memories into `.claude/memory/` (via the symlinked path is fine), put helper
scripts in `.claude/scripts/`, and make a git commit after every logical step (setup, each phase,
each green test milestone) — include memory changes in commits. Related: [[project-gpx-trail-app]].
