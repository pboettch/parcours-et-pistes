---
name: project-prerelease-formats
description: No project was ever created/deployed — every wire format is still v1; change formats in place, no version bumps, no migration or "recreate old projects" notes
metadata:
  type: project
---

No Parcours et Pistes project has ever been created for real (user, 2026-10-18): everything is
still **v1**. Format changes (ACL, envelope, content JSON, topic ids) are made in place, without
version bumps, compatibility code, migration steps or "projects created before must be
recreated" notes in docs.

**Why:** I bumped the ACL to v2 when replacing editors by assignments; the user corrected it:
"no project was ever created, so this is v1".

**How to apply:** until the first release, keep `version = 1` everywhere and describe only the
current format in `docs/DESIGN.md`. The forward-compatibility rules (unknown fields, `v` checks)
still matter for *after* the release. Related: [[project-overview]], [[project-runs-dog-path]].
