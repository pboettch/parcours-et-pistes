---
name: project-runs-dog-path
description: User decisions on runs (dog on a track), who shares the dog's position, bots, and the dog-path recording design (retained points + leader compaction)
metadata:
  type: project
---

**Runs (user, 2026-09-30):** at events several competing dogs work several tracks. The dog
carries no phone: its position is that of a member the project leader designates (the official
follower of the handler's group), changeable during the day (`Run.sources` keeps the history).
Tractive collars feed MQTT through an external service acting as a **bot member**.

**Dog path = user's design (implemented 2026-09-30):** no service. The designated member's app
publishes every position as its own retained item (`path_pt`, self; queued while offline); the
owner's/editors' sessions compact points older than 2 min into 15-minute `path` chunks (editors)
and purge the points (`SecureChannel.purge`), only those a stored chunk holds after a sync (safe
under concurrent compaction). Chunks name their member inside (pseudonyms change with the
password); the owner compacts before a password change. Limit: without an online editor the
single points pile up. A dedicated tracking service stays an idea for later.

**Open bugs (review 2026-10-18, `.claude/reviews/2026-10-18-dog-path.md`) — fix first in the next
library session:** concurrent compaction can lose points (stale `_decode` cache + same-rev race);
non-single-flight offline queue; path errors block the live position; password change can still
lose points; offline queue only in memory (DESIGN.md overstates).

**Progress** (`TrailProgress`, ported from the CCO prototype): distance to the track, confirmed
start near the beginning, forward-only cursor, end when the path leaves for good.

Related: [[project-overview]], [[reference-cco-prototype]].
