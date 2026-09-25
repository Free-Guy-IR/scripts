# Moving every installed copy to the fork's scripts

This is a supervised ops step for main to run after the fork's `main` is pushed at a tested commit `C` and its CI is
green. Run it on the test host 46.224 first, then on the nodes one at a time, and on the production panel last.
Nothing here has been run yet.

## 0. Preconditions

- The fork's `main` is at `C`, and nobody pushes to it during the migration. `install-script` downloads from
  `raw/main`, not from `C`.
- `parity/ROLLOUT.md` "Before every push to main" has passed for `C`.
- The host list comes from the KG fleet inventory. The node containers keep running throughout: `install-script`
  replaces only the CLI and its libraries.

## 1. Inventory (read-only, every host)

```bash
for f in /usr/local/bin/*; do
    [ -f "$f" ] && grep -q 'pasarguard-scripts' "$f" 2>/dev/null || continue
    printf '%s\t%s\t%s\t%s\n' "$f" \
        "$(grep -m1 -oE '(fetch_repo|FETCH_REPO)="[^"]+"' "$f")" \
        "$(grep -m1 -oE '^APP_NAME="[^"]*"' "$f")" \
        "$(sha256sum "$f" | cut -c1-16)"
done
ls -la /usr/local/lib/pasarguard-scripts/lib/ && sha256sum /usr/local/lib/pasarguard-scripts/lib/*.sh
systemctl list-units --type=service --no-pager | grep -E -- '-service\.service|serviced' || true
```

Record every line in the KG. Copies whose fetch repository is already `Free-Guy-IR/scripts` still get step 3, so
each host ends on the same commit.

## 2. Backup (every host, before any change)

```bash
backup=/root/pasarguard-scripts-backup-$(date -u +%Y%m%dT%H%M%SZ).tgz
tar -czf "$backup" <every /usr/local/bin path from step 1> /usr/local/lib/pasarguard-scripts
sha256sum "$backup"
```

Record `$backup` and its checksum in the KG.

## 3. Migrate each copy

- **`pasarguard` (panel hosts):**

  ```bash
  bash -c "$(curl -fsSL https://github.com/Free-Guy-IR/scripts/raw/C/pasarguard.sh)" @ install-script
  ```

- **`pg-node` under the default name:**

  ```bash
  bash -c "$(curl -fsSL https://github.com/Free-Guy-IR/scripts/raw/C/pg-node.sh)" @ install-script
  ```

- **A custom-named node `N`** (APP_NAME from step 1):
  - `pg-node.sh` refuses `install-script --name N` while `/usr/local/bin/N` exists, because it reads it as "an
    existing Linux command".
  - So move the old copy aside first. It is also in the step 2 backup:

  ```bash
  mv /usr/local/bin/N /root/N.pre-fork-migration
  bash -c "$(curl -fsSL https://github.com/Free-Guy-IR/scripts/raw/C/pg-node.sh)" @ install-script --name N
  ```

Run the copies of one host one after another, never in parallel. They share the library directory.

## 4. Verify (every host)

- Re-run step 1. Every copy must show `fetch_repo="Free-Guy-IR/scripts"`, or `FETCH_REPO` for `pg-node`.
  - A migrated `pasarguard` must hash equal to `raw/C/pasarguard.sh`.
  - A default-named `pg-node` must hash equal to `raw/C/pg-node.sh`.
  - A custom-named node's copy differs only in its `APP_NAME=` line, so compare it with that line removed.
- `<copy> status` works. On node hosts, `systemctl is-active <N>-service` shows the same state as before. On the
  panel host, the dashboard renders and one subscription page loads.
- `<copy> version-script` prints `unpinned (main)`: the fork's honest label for a copy with no baked commit.

## 5. Rollback (per host)

```bash
tar -xzf /root/pasarguard-scripts-backup-<stamp>.tgz -C /
```

This restores every script and the library directory as they were. A restored copy's next run refreshes the
libraries from its own old fetch repository again, so nothing else is needed. Remove any `/root/N.pre-fork-migration`
files only after the host has been verified.

## Order

1. **46.224:** all seven copies. Then watch 24 hours.
2. **Each node host, one at a time:** watch one panel-triggered node update on each.
3. **Production panel 188.245:** last, in a maintenance window. `pasarguard backup`, `restore` and the other
   commands switch from upstream's libraries to the fork's at that moment.
