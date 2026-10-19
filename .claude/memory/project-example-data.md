---
name: project-example-data
description: Example/demo data must be reproducible from the repo alone — simulated fictional trails (seed_example.dart), never a path to a local folder; real GPX files come later
metadata:
  type: project
---

The example project is built by `.claude/scripts/seed_example.dart` from fictional trails simulated
with `simulateTrail` (pep_content, fixed seeds). Its output (owner identity, link, password) goes to
`build/example/` (git-ignored, overridable with `--out`).

**Why:** user review of PR #2 (2026-10-18): the former `seed_cco.dart` read the private CCO site
copy from `~/devel/cco-prototype`, a dev folder that may disappear — "really bad". The club data is
private, so it can't move into the repo ([[reference-cco-prototype]]).

**How to apply:** no script, test or doc may depend on a folder outside the repo. For now
simulation is enough (user, 2026-10-18); GPX files for trails and real dog tracks will be added
to the repo later, and they must be fictional or cleared for publication.
