---
name: project-runs-dog-path
description: User decisions on runs (dog on a track), the designated position source, bots, the single-writer rule (recorder-only dog path with 20 rolling points + full track, owner-only runs, per-track owners)
metadata:
  type: project
---

**Runs (user, 2026-09-30):** at events several competing dogs work several tracks. The dog
carries no phone: its position is that of a member the project leader designates (the official
follower of the handler's group), changeable during the day (`Run.sources` keeps the history).
Tractive collars feed MQTT through an external service acting as a **bot member**.

**Simplify instead of handling concurrency (user, 2026-10-18, after the PR #3 review):** "for
concurrent things, maybe it's better to remove features rather than complicating things up".
Every item has a single writer:
- **Dog path = recorder only (user design, replaces leader compaction):** the recorder publishes
  its live position, the last points on **20 rolling retained topics** (slot = counter mod 20, the
  timestamp gives the order) and, every ~30 s (configurable), an updated **full track with all its
  points, per recording device** (user chose per recorder over one per run), in segments of 1000
  points (only the open one is republished). A newcomer reads the
  run's current source X, X's full track + X's rolling points (merged by time). No compaction, no
  purge, no editor writing others' points.
- **Runs: owner only.**
- **Tracks: one owner per track** (single writer), assigned by the project owner; the global
  "editors" role disappears. The project owner itself is fixed (no ownership transfer,
  [[project-no-password-change]]). (User chose this over "project owner can always edit too".)
- Bugs found then, all fixed in PR #3: stale `_decode` cache; tie rule for equal (rev, time) =
  the one received last wins, like the broker (chosen over a deterministic tie-break); MQTT
  publishes hanging after a disconnect. ("Close when locked" is moot: no locked state.)
- Later: the judge writes reports on a track, on a separate topic of the judge user.

**No password change for now (user, 2026-10-19):** "Forget the password change mechanism. We will
add this later." A compromised project is replaced: the owner creates a new project from their
local copy (anyone can create a project from one synced locally). The intermediate design
(kept collections with a seed, owner re-encrypting recorded paths) was removed with it; it is on
the local branch `archive/runs-dog-path-pre-rewrite` if password changes come back.

**Implemented 2026-10-18** (PR #3, merged 2026-10-19): `Writers.assigned` + ACL `assign` map (format v1),
`SecureChannel.assign` (owner re-signs on reassignment), `RecordedPath`,
`ProjectSession.flushPath`/`pathInterval`/`assignTrack`. 

**Previous design (removed):** retained point per position, owner/editors compact into 15-min
chunks and purge the points. Reviews: `.claude/reviews/2026-10-19-pr3.md`.

**Progress** (`TrailProgress`, ported from the CCO prototype): distance to the track, confirmed
start near the beginning, forward-only cursor, end when the path leaves for good.

Related: [[project-overview]], [[reference-cco-prototype]].

**Reconnect wait kept and fixed (user, 2026-10-19):** after a reconnect the channel reloads
(subscribe if needed + sync barrier) before writing; asked "fix or remove", the user chose fix.
