---
name: reference-github-repo
description: GitHub repository pboettch/parcours-et-pistes (public), CI workflow and how to check runs with gh
metadata:
  type: reference
---

- Repository: https://github.com/pboettch/parcours-et-pistes (public), remote `origin` =
  `git@github.com:pboettch/parcours-et-pistes.git` (SSH works from this machine).
- `gh` CLI is installed and authenticated as pboettch (keyring): `gh run list`, `gh run watch <id>`,
  `gh run view <id> --log-failed`.
- CI: `.github/workflows/ci.yml` (push to main + pull requests). First runs green on 2026-09-29.
  Codecov not yet set up (needs `CODECOV_TOKEN` secret); branch protection not yet configured.
- Related: [[project-gpx-trail-app]], [[feedback-repo-conventions]].
