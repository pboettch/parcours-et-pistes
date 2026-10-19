---
name: project-gui-direction
description: User's GUI ideas for the apps (overview window, single-track window for poseurs and judges, layers) and the parked web PoC
metadata:
  type: project
---

**User's GUI direction (2026-09-30, still thinking — don't implement before they decide):**
- The overview of all trails of a project = a **dedicated window** (like the CCO card page).
- The **single-track window** is the most used part: the *poseur* follows the planned track with
  their own position to know they are on it and where to put the objects (track *recording*
  comes later); judges/trainers follow the dog during the search.
- Map layers wanted: IGN, OSM Rando, OSM, satellite. App opens on the map at the current
  position, with a menu for the rest. Web first for the PoC.

**Web PoC** lives on the pushed, **unmerged** branch `poc-web` (`apps/pep_app`, run with
`.claude/scripts/app.sh` there), **parked** (user, 2026-10-18): focus on the libraries.
It **will not be merged as is** (user, 2026-10-18): the real app's design and functionality will
differ; parts of the PoC will be reused.
It ran on a private example project seeded from the CCO site copy; that seed script was replaced
by `.claude/scripts/seed_example.dart` (simulated trails, see [[project-example-data]]).

Related: [[project-overview]], [[reference-dev-environment]].
