# Research: Compose-File Contract

## R1. Which override file Compose loads

- **Decision**: the first existing file among `compose.override.yml`, `compose.override.yaml`,
  `docker-compose.override.yml`, `docker-compose.override.yaml`, in the base file's directory,
  loaded after the base file.
- **Rationale**: measured with Docker Compose v5.6.0 in a directory holding all four names: with
  no `-f`, Compose warned "Found multiple override files" and used them in exactly this order as
  each was removed. With `-f docker-compose.yml` alone it resolved the base image; with
  `-f docker-compose.yml -f docker-compose.override.yml` it resolved the override's image.
- **Alternatives considered**: dropping `-f` and running Compose in the app directory. Rejected:
  Compose would then prefer a stray `compose.yaml` over `docker-compose.yml` as the base file,
  which changes the base file.

## R2. Where the helper lives

- **Decision**: `lib/docker.sh`, next to `compose_up` and friends.
- **Rationale**: an old installed script refreshes only its libraries, and its restart, update,
  up and down all go through `compose_up` and `compose_down`, so those gain the fix without a
  script reinstall.
- **Alternatives considered**: defining the helper in each script. Rejected: old scripts would
  never get it, and two copies drift.

## R3. A new script with an old library

- **Decision**: after sourcing the libraries, each script checks that `compose_cmd` exists and
  otherwise prints the outdated library path and exits 1.
- **Rationale**: inside `$(...)` and `if` a missing function only prints "command not found" and
  yields empty output, so `is_pasarguard_up` would silently report "down".
- **Alternatives considered**: a fallback definition with the old behaviour. Rejected: it would
  bring the rollback back silently.

## R4. Image writes at install time

- **Decision**: after an install writes the image into the base file, print a notice naming the
  override when one is present.
- **Rationale**: a reinstall over an existing directory keeps the old override, which now wins.
  Saying so keeps the behaviour visible without overriding the operator's own file.
- **Alternatives considered**: editing the override's image, or refusing the install. Rejected:
  the override is the operator's file, and the reinstall prompt already asked for confirmation.
