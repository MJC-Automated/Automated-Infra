# Public Mirror Workflow

This repository includes a sanitize-and-publish pipeline for maintaining a public mirror while keeping the source repository private.

## Why This Exists

GitHub visibility is set at the repository level, not per branch. Public repositories expose all pushed branches.  
Use this workflow when you need private development branches but a public sanitized mirror for selected branches.

## Branch Strategy

Private source branches:

- `main`
- `develop`
- `terraform-proxmox-automated-infra`

Public mirror branches:

- `main`
- `develop`
- `terraform-proxmox-automated-infra`

## Required GitHub Configuration (Private Source Repo)

Set these in the private source repository where CI runs:

1. Repository variable: `PUBLIC_MIRROR_REPO`
   - Format: `owner/repo`
   - Example: `MJC-Automated/Automated-Infra`

2. Repository variable: `PUBLIC_MIRROR_APP_ID`
   - Numeric GitHub App ID used to mint short-lived installation tokens.

3. Repository secret: `PUBLIC_MIRROR_APP_PRIVATE_KEY`
   - GitHub App private key PEM for token generation.
   - Keep this secret restricted to this workflow and rotate if exposed.

## GitHub App Setup (Public Mirror Repo)

1. Create or reuse a GitHub App under your organization.
2. Grant repository permissions:
   - `Contents: Read and write`
3. Install the app on the public mirror repository (`Automated-Infra`).
4. Copy the App ID and private key PEM into:
   - `PUBLIC_MIRROR_APP_ID` (variable)
   - `PUBLIC_MIRROR_APP_PRIVATE_KEY` (secret)

## Workflow File

- `.github/workflows/public-mirror.yml`

Triggers:

- Pushes to `main`, `develop`, `terraform-proxmox-automated-infra`
- Manual run (`workflow_dispatch`) with optional dry-run mode

Behavior:

1. Applies deterministic replacements from `.github/sanitize/replacements.regex.tsv`
2. Applies path/file renames from `.github/sanitize/path-renames.tsv`
3. Fails if denylist patterns remain (`.github/sanitize/denylist.regex`)
4. Publishes sanitized snapshot to the public mirror branch
5. Excludes `.github/sanitize/` and `.github/workflows/public-mirror.yml` from the public mirror output

## Local Preflight (Optional)

Run this before opening/merging changes:

```bash
bash scripts/public-release/sanitize.sh
bash scripts/public-release/scan.sh
```

## Notes

- `scripts/public-release/publish.sh` syncs a sanitized snapshot into the target public branch and commits only if content changed.
- Keep replacement and denylist files up to date as new sensitive markers are discovered.
