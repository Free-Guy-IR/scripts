# Feature Specification: Compose-File Contract

**Feature Branch**: `fix/compose-override`

**Created**: 2026-10-10

**Status**: Draft

**Input**: User description: "Every pasarguard and pg-node compose call passes only the base
docker-compose.yml, so the override file next to it is never loaded. On a host whose override pins
the panel or node image, a CLI restart, update or panel-triggered node action recreates the
containers from the base file alone and silently rolls the image back (bug INFRA-W4A-044)."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A restart keeps the pinned panel image (Priority: P1)

An operator has pinned the panel image in the override file next to the base compose file. They
run `pasarguard restart` (or `pasarguard update`, `pasarguard up`, `pasarguard down`). The panel
comes back on the pinned image, with every other override setting still applied.

**Why this priority**: today this silently downgrades production to whatever older image the base
file names, which is the reported bug.

**Independent Test**: a test creates an app directory with a base file naming one panel image and
an override naming another, runs the real restart command with a recording stand-in for Compose,
and checks that every recorded call loads both files, and that Compose itself resolves the
override's image from those exact arguments.

**Acceptance Scenarios**:

1. **Given** a base file with panel image A and an override with panel image B, **When** the
   operator runs `pasarguard restart`, **Then** both the stop and the start load the base file and
   the override, and the resolved panel image is B.
2. **Given** the same files, **When** the operator runs `pasarguard update`, **Then** the pull, the
   stop and the start all load both files.
3. **Given** a base file and no override, **When** any command runs, **Then** the Compose
   arguments are exactly what they were before this change.

---

### User Story 2 - Node actions keep the pinned node image (Priority: P1)

A node host pins its node image in the override. The operator, or the panel through
node-serviced, runs `pg-node restart`, `pg-node update`, `pg-node up`, `pg-node down` or another
command that recreates the node. The node keeps the pinned image.

**Why this priority**: the panel triggers these actions on every fork node without a human
watching, so a rollback there goes unnoticed.

**Independent Test**: the same recording approach, against the real `pg-node` restart and update
paths.

**Acceptance Scenarios**:

1. **Given** a node directory whose override pins node image B over the base file's image A,
   **When** `pg-node restart` runs, **Then** both the stop and the start load the override and
   the resolved node image is B.
2. **Given** the same directory, **When** `pg-node update` pulls images, **Then** the pull loads
   the override.

---

### User Story 3 - Mixed script and library versions stay safe (Priority: P2)

An installed host runs an older `pasarguard` or `pg-node` script while its shared libraries are
refreshed to this version, or the reverse.

**Why this priority**: a push to `main` reaches fork hosts' libraries within minutes, while the
scripts themselves change only on reinstall.

**Independent Test**: run the older script's stop and start paths with the new library, and the
new script with the older library.

**Acceptance Scenarios**:

1. **Given** the previous script and the new library, **When** a restart runs, **Then** it works
   and the library's start and stop load the override.
2. **Given** the new script and a library that predates this change, **When** the script starts,
   **Then** it stops with a clear message naming the outdated library file and exits non-zero,
   instead of running Compose with half the files.

---

### User Story 4 - An install says when an override will win (Priority: P3)

An operator reinstalls over an existing directory that still holds an override. The install writes
the requested image into the base file.

**Independent Test**: run the image-writing step with an override present and check the message.

**Acceptance Scenarios**:

1. **Given** an existing override, **When** the install writes the image into the base file,
   **Then** the CLI prints that the override is also loaded and takes precedence, naming the file.
2. **Given** no override, **When** the install writes the image, **Then** no such message appears.

### Edge Cases

- Several override names exist at once: only the first in Compose's own order is loaded,
  `compose.override.yml`, `compose.override.yaml`, `docker-compose.override.yml`,
  `docker-compose.override.yaml`, which matches what `docker compose` does in that directory.
- The override is a directory or a broken link: it is not a regular file and is not loaded.
- The app directory path contains spaces: the library passes each file as one argument. (Other
  unquoted uses of the app directory in the scripts predate this change and stay out of scope.)
- Calls that never passed a project name keep not passing one.
- The certbot renewal hook's stored restart command is unchanged; a restart never recreates
  containers, so it cannot change the image.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Every Compose call made by `pasarguard`, `pg-node`, the standalone wrappers and the
  shared libraries MUST load the base compose file and, when one exists next to it, the override
  that Compose itself would load in that directory. The upstream-identical
  `lib/pasarguard-backup.sh` and `lib/pasarguard-restore.sh` are the only exception: their own
  Compose calls only list services and containers, or start the database during `restore --fresh`
  on an empty server, and every stop and start of an existing installation goes through
  `compose_up`, `compose_down` and the scripts' service functions, which carry the fix.
- **FR-002**: The override MUST be chosen as the first existing regular file among
  `compose.override.yml`, `compose.override.yaml`, `docker-compose.override.yml` and
  `docker-compose.override.yaml` in the base file's directory, and it MUST be loaded after the
  base file.
- **FR-003**: With no override present, the arguments passed to Compose MUST be identical to the
  arguments passed before this change.
- **FR-004**: Each call MUST keep its existing project-name handling: calls that passed
  `-p "$APP_NAME"` keep it, calls that did not keep not passing it.
- **FR-005**: The shared library's existing `compose_up`, `compose_down`, `compose_logs` and
  `compose_logs_follow` MUST keep their names and calling conventions, so that older installed
  scripts gain the fix through a library refresh alone.
- **FR-006**: A script of this version running with a shared library that lacks the new helper MUST
  stop before running any command, print which library file is outdated, and exit non-zero.
- **FR-007**: When an install writes an image into the base file while an override is present, the
  CLI MUST print that the override is also loaded and takes precedence, naming the override file.
- **FR-008**: Changed shell files MUST be shellcheck clean and carry no explanatory comments.

### Key Entities

- **Base compose file**: `$APP_DIR/docker-compose.yml`, written by the installer.
- **Override file**: the operator's file next to it that Compose layers on top of the base file.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With an override that pins an image, 100% of the recorded Compose calls made by the
  restart, update, up and down paths of both CLIs load the override, and Compose resolves the
  pinned image from those arguments.
- **SC-002**: Without an override, 100% of the recorded calls are byte-identical to the previous
  version's.
- **SC-003**: The new test fails on the parent commit and passes on the fix.
- **SC-004**: Every existing test suite still passes.

## Assumptions

- Hosts run Docker Compose v2, which the scripts already require.
- The base file is always `$APP_DIR/docker-compose.yml`; choosing a different base file is out of
  scope.
- Production rollout is the owner's decision. The production panel's installed `pasarguard`
  currently fetches upstream's libraries, so it gains this fix only after its migration to the
  fork's scripts.
- `lib/pasarguard-backup.sh` and `lib/pasarguard-restore.sh` stay upstream-identical, as FR-001
  describes.
