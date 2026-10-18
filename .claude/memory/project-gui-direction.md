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

**Web PoC (`apps/pep_app`)** exists but is **parked** (user, 2026-10-18): focus on the libraries.
It runs on the private example project seeded from the CCO site ([[reference-cco-prototype]]).

Related: [[project-overview]], [[reference-dev-environment]].
