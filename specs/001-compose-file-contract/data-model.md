# Data Model: Compose-File Contract

## Compose file set

| Field | Source | Rule |
|---|---|---|
| base | `$COMPOSE_FILE` (`$APP_DIR/docker-compose.yml`) | always first |
| override | first regular file among the four override names in `dirname $COMPOSE_FILE` | second, when present |

No persisted state is added. The set is computed for every Compose call, so an override created,
renamed or removed between two commands is picked up by the next command.
