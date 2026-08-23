# Public Mirror Workflow

This repository includes a sanitize-and-publish pipeline for maintaining a public mirror while keeping the source repository private.

## Why This Exists

GitHub visibility is set at the repository level, not per branch. Public repositories expose all pushed branches.
Use this workflow when you need private development branches but a public sanitized mirror for selected branches.

## Branch Strategy

The active GitHub Actions workflow publishes the private repository's `main`
branch to `MJC-Automated/Automated-Infra:main`. The local
`scripts/public-release/publish.sh` helper can target another branch, but it is
an operator-run alternate path rather than the active workflow.

## Required GitHub Configuration (Private Source Repo)

Set these in the private source repository where CI runs:

1. Repository variable: `SANITIZER_APP_ID`
   - Numeric GitHub App ID used to mint a short-lived installation token.

2. Repository secret: `SANITIZER_APP_PRIVATE_KEY`
   - GitHub App private key PEM for token generation.
   - Keep this secret restricted to this workflow and rotate if exposed.

## GitHub App Setup (Public Mirror Repo)

1. Create or reuse a GitHub App under your organization.
2. Grant repository permissions:
   - `Contents: Read and write`
3. Install the app on the public mirror repository (`Automated-Infra`).
4. The workflow requests `Contents: write` for the `Automated-Infra`
   repository and uses the token only for that publication job.

## Workflow File

- `.github/workflows/publish-sanitized-snapshot.yml`

Triggers:

- Pushes to `main`
- Manual run (`workflow_dispatch`)

Behavior:

1. Applies deterministic replacements from `.github/sanitize/replacements.regex.tsv`
2. Applies path/file renames from `.github/sanitize/path-renames.tsv`
3. Fails if denylist patterns remain (`.github/sanitize/denylist.regex`)
4. Publishes sanitized snapshot to the public mirror branch
5. Excludes `.github/sanitize/` and all private workflow files from the public
   mirror output

## Local Preflight (Optional)

Run this before opening/merging changes:

```bash
bash scripts/public-release/sanitize.sh
bash scripts/public-release/scan.sh
```

## Notes

- The active workflow calls `scripts/export_sanitized_snapshot.py`, which copies
  tracked files only, sanitizes private identifiers, and replaces the target
  repository contents.
- `scripts/public-release/publish.sh` is an alternate local helper. It syncs a
  sanitized snapshot into a target branch and commits only if content changed;
  run it only in a disposable clone.
- Keep replacement and denylist files up to date as new sensitive markers are discovered.
