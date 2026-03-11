# Future Ideas

This appendix is intentionally separate from the current-state chapters.

Everything below is a documentation or platform expansion idea. None of it should be read as "already implemented in the repo" unless a future revision moves it into the main chapters with tracked code or committed docs behind it.

## Documentation Expansions

- Add a source index that maps major operator questions to the exact repo files that answer them.
- Add a per-service troubleshooting appendix with "symptom -> likely source file -> likely fix path."
- Add a command reference appendix for the most common `make`, `packer`, `terraform`, and `ansible-playbook` entrypoints.
- Add a dedicated `inventory-and-aliases` chapter if the number of helper groups keeps growing.
- Add one chapter per environment family such as `dev` if environment conventions start to diverge materially.

## Automation and Platform Ideas

- Add ADR-style documents for repo decisions such as inventory generation, Vault auth mode choices, and the split between base VMs and Packer templates.
- Add an architecture chapter for controller-machine assumptions, including pyenv, local shared directories, and `.vault_password` handling.
- Add an explicit day-2 operations runbook for credential rotation, backup verification, and partial rebuilds.
- Add a repo-wide dependency map showing which services are hard prerequisites, soft prerequisites, or just common companions.

## Verification and Workflow Ideas

- Add a chapter that catalogs where each project keeps its validation logic.
- Add a generated matrix that compares playbook entrypoint patterns across services.
- Add a lightweight smoke-check playbook or CI-facing wrapper when the repo is ready for a central verification surface again.
- Add a chapter that explains which generated outputs are worth preserving and which are safe to discard.

## Service-Layer Ideas

- Add a deeper Oracle listener and service-registration appendix once the repo intentionally documents the static-vs-dynamic listener model.
- Add a FreeIPA and Keycloak identity-flow chapter if the repo grows explicit federation or SSO integration automation.
- Add a Zimbra operational appendix covering DNS and mail-routing practices only when those details become tracked configuration, not just operator knowledge.
- Add a reusable service-template guide based on the Zabbix modular pattern for onboarding new projects under `bootstrap_playbooks/`.

## Diagram Ideas

- Add a dedicated secrets-lifecycle diagram showing rotation, bootstrap, and fallback behavior.
- Add a VM disk lifecycle diagram from tfvars partition data to guest-visible mountpoints.
- Add a controller-runtime diagram showing which pyenv virtualenvs map to which projects and scripts.
- Add a service-dependency diagram that distinguishes baseline layers from application layers.

## Rule for Future Revisions

If any idea in this appendix becomes implemented and visible in tracked code or committed docs:

1. move it into the relevant main chapter
2. add source links
3. remove or shrink the corresponding item here

That keeps the main docs codebase-oriented and the appendix aspirational.
