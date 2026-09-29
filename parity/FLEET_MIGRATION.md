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
- Every command below runs as root in a fresh empty directory:

  ```bash
  cd "$(mktemp -d)"
  ```

  A script started with `bash -c "$(curl ...)"` takes its working directory as its own directory. It sources
  `./lib/*.sh` from there if they exist, instead of the libraries it was tested with.

## 1. Inventory (read-only, every host)

### Script copies

```bash
for f in /usr/local/bin/*; do
    [ -f "$f" ] && grep -Iq 'pasarguard-scripts' "$f" 2>/dev/null || continue
    if grep -q 'STANDALONE_INSTALL_ROOT=' "$f"; then
        printf '%s\tSTANDALONE\t%s\n' "$f" "$(sha256sum "$f" | cut -c1-16)"
        continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$f" \
        "$(grep -m1 -oE '(fetch_repo|FETCH_REPO)="[^"]+"' "$f")" \
        "$(grep -m1 -oE '^APP_NAME="[^"]*"' "$f")" \
        "$(sha256sum "$f" | cut -c1-16)"
done
ls -la /usr/local/lib/pasarguard-scripts/ /usr/local/lib/pasarguard-scripts/lib/
sha256sum /usr/local/lib/pasarguard-scripts/lib/*.sh
systemctl list-units --type=service --no-pager | grep -E -- '-service\.service|serviced' || true
```

- Record every line in the KG.
- Copies whose fetch repository is already `Free-Guy-IR/scripts` still get step 3, so each host ends on the same
  commit.
- **`STANDALONE` rows are left out of this migration.** They are wrappers from the offline bundle
  (`iran-sanction/pg-node-standalone.sh`). They run the `pg-node.sh` and libraries bundled under
  `/usr/local/lib/pasarguard-scripts/pg-node-standalone/` and never refresh from GitHub, so a push to `main` does
  not reach them.
  - Running `install-script` on one would replace the offline bundle with an online copy.
  - Moving them to the fork means installing the fork's `pg-node-standalone.tar.gz` release. That needs its own
    decision from the owner, host by host.

### Each copy's directories and compose files

For each non-standalone copy `N` from the table: `APP_DIR` is `/opt/N`. `DATA_DIR` is `/var/lib/N` for a node and
`/var/lib/pasarguard` for the panel.

```bash
app_dir=/opt/N
data_dir=/var/lib/N
ls -la "$app_dir" "$data_dir"
ls -la "$app_dir"/*override* 2>/dev/null || echo "no override file in $app_dir"
docker compose -f "$app_dir/docker-compose.yml" config --images | sort
(cd "$app_dir" && docker compose config --images | sort)
diff <(docker compose -f "$app_dir/docker-compose.yml" config) <(cd "$app_dir" && docker compose config) &&
    echo "override changes nothing"
```

- The first `config --images` is what every `pasarguard` and `pg-node` command runs. `lib/docker.sh`, `update_node`
  and the panel's service helpers all pass `-f docker-compose.yml`, so Compose ignores `docker-compose.override.yml`.
- The second is what `docker compose up` run by hand in `$app_dir` runs, with the override merged in.
- **STOP when the image lists differ.** Do not migrate that host, do not restart it and do not trigger any update
  on it. The first `update`, `restart`, `core-update` or panel-triggered node action recreates the container from
  the base file alone, which swaps its image.
  - Record the difference in the KG and hand it to the owner.
  - The owner then decides whether to move the pin into `docker-compose.yml` or to keep that host out of the
    scripts' restarts.
- **STOP as well when the full `config` diff shows any other difference**, such as ports, volumes, environment or
  devices. The same restarts drop those settings too.
- Record the `ls -la` output. The rollback uses it to tell which files the migration created.

## 2. Backup (every host, before any change)

```bash
backup=/root/pasarguard-scripts-backup-$(date -u +%Y%m%dT%H%M%SZ).tgz
(umask 077 && tar -czf "$backup" \
    <every /usr/local/bin path from step 1, STANDALONE rows included> \
    /usr/local/lib/pasarguard-scripts \
    <for every copy N: /opt/N/.env, /opt/N/docker-compose.yml, and every /opt/N/*override* file>)
chmod 600 "$backup"
sha256sum "$backup"
```

- The archive holds `.env` files with `API_KEY` and the database credentials. Keep it at mode 0600 on the host.
  Never copy it off the host, and never into git.
- Record `$backup` and its checksum in the KG, but not its contents.

## 3. Migrate each copy

Run each command from a fresh empty directory (see step 0). Download with a time limit, then run the file:

- **`pasarguard` (panel hosts):**

  ```bash
  cd "$(mktemp -d)"
  curl -fsSL --connect-timeout 15 --max-time 60 https://github.com/Free-Guy-IR/scripts/raw/C/pasarguard.sh -o pasarguard.C.sh
  bash -c "$(cat pasarguard.C.sh)" @ install-script
  ```

- **`pg-node` under the default name:**

  ```bash
  cd "$(mktemp -d)"
  curl -fsSL --connect-timeout 15 --max-time 60 https://github.com/Free-Guy-IR/scripts/raw/C/pg-node.sh -o pg-node.C.sh
  bash -c "$(cat pg-node.C.sh)" @ install-script
  ```

- **A custom-named node `N`** (APP_NAME from step 1):
  - `pg-node.sh` refuses `install-script --name N` while `/usr/local/bin/N` exists, because it reads it as "an
    existing Linux command".
  - So move the old copy aside first. It is also in the step 2 backup:

  ```bash
  cd "$(mktemp -d)"
  curl -fsSL --connect-timeout 15 --max-time 60 https://github.com/Free-Guy-IR/scripts/raw/C/pg-node.sh -o pg-node.C.sh
  mv /usr/local/bin/N /root/N.pre-fork-migration
  bash -c "$(cat pg-node.C.sh)" @ install-script --name N
  ```

Run the copies of one host one after another, never in parallel. They share the library directory.

`install-script` is not read-only for a node. Like every `pg-node` command, it first runs `sync_env_ssl_paths`.

- For a custom-named node whose `.env` still points `SSL_CERT_FILE` or `SSL_KEY_FILE` at `/var/lib/pg-node`, that
  rewrites the two lines to the node's own `DATA_DIR`.
- It also creates `/opt/N/.env.lock`.
- Commands that make temporary files create `DATA_DIR/tmp`.

Step 4 checks these effects, and step 5 undoes them.

## 4. Verify (every host)

- Re-run step 1. Every non-standalone copy must show `fetch_repo="Free-Guy-IR/scripts"`, or `FETCH_REPO` for
  `pg-node`.
- **Compare each copy with `C` byte for byte.** `install-script` rewrites the `APP_NAME=` line of `pg-node.sh`:
  - it becomes `APP_NAME="pg-node"` for the default name;
  - it becomes `APP_NAME="N"` for a custom name.

  So reset that one line before comparing. `pasarguard.sh` is installed unchanged:

  ```bash
  cmp /usr/local/bin/pasarguard pasarguard.C.sh
  sed 's|^APP_NAME=.*|APP_NAME=""|' /usr/local/bin/pg-node | cmp - pg-node.C.sh
  sed 's|^APP_NAME=.*|APP_NAME=""|' /usr/local/bin/N | cmp - pg-node.C.sh
  for lib in /usr/local/lib/pasarguard-scripts/lib/*.sh; do
      curl -fsSL --connect-timeout 15 --max-time 60 "https://github.com/Free-Guy-IR/scripts/raw/C/lib/$(basename "$lib")" | cmp - "$lib"
  done
  ```

- **Check each `.env` against the backup.** The only allowed difference is the `SSL_CERT_FILE` and `SSL_KEY_FILE`
  lines that `sync_env_ssl_paths` moved to the node's own `DATA_DIR`. Any other difference: stop and roll back that
  host.

  ```bash
  diff <(tar -xzOf "$backup" opt/N/.env) /opt/N/.env
  ```

- `<copy> status` works. On node hosts, `systemctl is-active <N>-service` shows the same state as before. On the
  panel host, the dashboard renders and one subscription page loads.
- `<copy> version-script` prints `unpinned (main)`: the fork's honest label for a copy with no baked commit.

## 5. Rollback (per host)

1. **Restore the scripts and libraries:**

   ```bash
   tar -xzf "$backup" -C / usr/local/bin usr/local/lib/pasarguard-scripts
   ```

2. **Restore each `.env` only if nothing else has written it since.**
   - Compare the live `.env` with the backup, as in step 4.
   - If the only difference is the SSL lines from `sync_env_ssl_paths`, restore it from the archive:

     ```bash
     tar -xzf "$backup" -C / opt/N/.env
     ```

   - If anything else differs, a later legitimate write happened, for example `API_PORT`, `XRAY_EXECUTABLE_PATH`
     or `XRAY_ASSETS_PATH` from a panel action. Do not overwrite it. Revert only the two SSL lines by hand, and
     record that in the KG.
3. **Remove what the migration created.** Compare `ls -la /opt/N /var/lib/N` with the step 1 record, then remove
   only these entries, and only if they were not there before:
   - `/opt/N/.env.lock`
   - `/var/lib/N/tmp`

   Leave any `..env.edit-*` file in place and tell the owner. It is an admin's unsaved `edit-env` copy, and it
   holds `API_KEY`.
4. **Keep the moved-aside copies until the host is verified.** Remove `/root/N.pre-fork-migration` only after
   that, whether the host was rolled back or verified.

A restored copy's next run refreshes the libraries from its own old fetch repository again.

## Order

1. **46.224:** all copies except `STANDALONE` rows, then watch 24 hours.
2. **Each node host, one at a time.** Only a host whose step 1 compose check passed is migrated. On it, watch one
   panel-triggered node update.
   - That update recreates the node from `docker-compose.yml` alone.
   - A host where the override changes anything never gets here: it stopped at step 1.
3. **Production panel 188.245:** last, in a maintenance window, and only if step 1 found no override difference
   there.
   - `pasarguard backup`, `restore` and the other commands switch from upstream's libraries to the fork's at that
     moment.
