# Contract: Compose invocation

## `compose_override_file`

- Reads `COMPOSE_FILE`.
- Prints the path of the first regular file among `compose.override.yml`,
  `compose.override.yaml`, `docker-compose.override.yml`, `docker-compose.override.yaml` in the
  directory of `COMPOSE_FILE`, and returns 0.
- Returns 1 and prints nothing when none exists.

## `compose_cmd ARGS...`

- Runs `$COMPOSE -f "$COMPOSE_FILE" -f "<override>" ARGS...` when an override exists.
- Runs `$COMPOSE -f "$COMPOSE_FILE" ARGS...` otherwise.
- Returns Compose's exit status.

## Library entry points (unchanged names)

| Function | Runs |
|---|---|
| `compose_up` | `compose_cmd -p "$APP_NAME" up -d --remove-orphans` |
| `compose_down` | `compose_cmd -p "$APP_NAME" down` |
| `compose_logs` | `compose_cmd -p "$APP_NAME" logs` |
| `compose_logs_follow` | `compose_cmd -p "$APP_NAME" logs -f` |

## `compose_override_notice`

- Prints one warning line naming the override when `compose_override_file` finds one.
- Prints nothing otherwise. Always returns 0.

## Script start-up

- `pasarguard` and `pg-node` exit 1 with `Shared library <dir>/docker.sh is older than this
  script ...` when `compose_cmd` is not defined after the libraries are sourced.
