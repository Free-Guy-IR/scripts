# Quickstart: validate the compose-file contract

## Prerequisites

- A checkout of this repository.
- Optional: a Docker Compose v2 binary. Set `DOCKER_COMPOSE_BIN` to a standalone `docker-compose`
  binary, or have `docker compose` on `PATH`. Without one, the resolution checks print `SKIP`.

## Run

```bash
bash tests/run_isolated.sh tests/test_compose_override_honoured.sh
```

## Expected

- On the fix: every line is `PASS` (or `SKIP` for the Compose resolution checks when no Compose
  binary exists) and the exit status is 0.
- On the parent commit: the override checks print `FAIL` and the exit status is 1.

## Full regression

```bash
bash tests/run_all.sh
for t in tests/test_*.sh; do bash tests/run_isolated.sh "$t" || echo "FAILED $t"; done
```
