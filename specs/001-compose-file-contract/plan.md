# Implementation Plan: Compose-File Contract

**Branch**: `fix/compose-override` | **Date**: 2026-10-10 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-compose-file-contract/spec.md`

## Summary

Every Compose call in the CLIs passes only `-f docker-compose.yml`, so the operator's override is
never loaded and recreating commands roll pinned images back. One helper in `lib/docker.sh` builds
the same file list Compose itself would load in the app directory, and every call site uses it.
The library's existing entry points keep their names, so old installed scripts gain the fix
through a library refresh, and new scripts refuse to run with a library that lacks the helper.

## Technical Context

**Language/Version**: Bash; tests also run under macOS bash 3.2

**Primary Dependencies**: Docker Compose v2 (already required by `detect_compose`)

**Storage**: N/A

**Testing**: shell test scripts in `tests/`, run through `tests/run_isolated.sh`; a recording
stand-in for `docker` on `PATH`; real Compose resolution when a Compose binary is available

**Target Platform**: Linux hosts running the panel or a node

**Project Type**: CLI scripts with a shared shell library

**Performance Goals**: N/A (one extra file test per Compose call)

**Constraints**: old script with new library must keep working; no new runtime dependency

**Scale/Scope**: 2 CLIs, 2 standalone wrappers, 1 library file

## Constitution Check

| Principle | Status |
|---|---|
| I. Test-first | RED test committed before the fix and shown failing on the parent |
| II. Parity | No upstream file is changed except the call sites inside fork-modified scripts; `lib/docker.sh` divergence is recorded in `parity/DIVERGENCES.md` |
| III. No comments, shellcheck | New code has no comments; shellcheck run on every changed file |
| IV. Installed hosts | `compose_up`, `compose_down`, `compose_logs`, `compose_logs_follow` keep their names and globals; the skew test proves old-script use |
| V. No secrets | Test fixtures use placeholder image names only |
| VI. Fail loudly | A new script with an old library exits non-zero naming the outdated file |

Post-design re-check: no violations.

## Project Structure

### Documentation (this feature)

```text
specs/001-compose-file-contract/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/compose-invocation.md
├── checklists/requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
lib/docker.sh                       compose_override_file, compose_cmd, compose_override_notice
pasarguard.sh                       call sites, library check, install notice
pg-node.sh                          call sites, library check, install notice
iran-sanction/pasarguard-standalone.sh   install notice
iran-sanction/pg-node-standalone.sh      install notice
tests/test_compose_override_honoured.sh  new
.github/workflows/fork-regression-tests.yml   runs the new test
parity/DIVERGENCES.md               records the lib/docker.sh divergence
```

**Structure Decision**: single repository, existing layout.

## Complexity Tracking

No constitution violations to justify.
