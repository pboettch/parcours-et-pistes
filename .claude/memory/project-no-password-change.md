---
name: project-no-password-change
description: Password change and ownership transfer removed (user 2026-10-19) — compromised or handed-over project → new project created from a local copy
metadata:
  type: project
---

The project password never changes (user, 2026-10-19): "Forget the password change mechanism.
We will add this later. For now, when a project has been 'attacked', the owner will create a new
one, based on the previous (everyone can actually create a project from one it has synced
locally) and that's it."

**Why:** a password change only hides what comes next (an excluded person keeps what they
decrypted), and carrying members' own items across a key change needed seeds, re-encryption and
three review rounds of edge cases — against the "remove rather than complicate" rule
([[project-runs-dog-path]]).

**How to apply:** no `changePassword`/`unlock`/locked state/`PasswordChanged` in the libraries.
Exclusion = new project. "Create a project from a local copy" (tracks, runs, assignments…) is an
upcoming feature (`docs/TODO.md`). The removed design is on the local branch `archive/runs-dog-path-pre-rewrite`.

**Ownership transfer removed too (user, 2026-10-19, after the 5th review):** an interrupted
transfer (between its ACL, meta and re-sign steps) made the project unjoinable, and hardening it
needed resumable state. The owner is now fixed (the creator, pinned by the join link); to hand a
project over, the new owner creates a new project from their local copy. Same upcoming feature.
