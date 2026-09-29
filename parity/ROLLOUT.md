# How a push to main reaches installed hosts

## What an installed copy fetches

Every installed `pasarguard` and `pg-node` copy is a single script in `/usr/local/bin`. On every run it refreshes
the shared libraries in `/usr/local/lib/pasarguard-scripts/lib/` from `https://github.com/<fetch_repo>/raw/main/lib/`.

- **Where `<fetch_repo>` comes from:** it is hardcoded in the copy's `bootstrap_*_shared_libs` function. It is
  whatever repository the copy was installed from.
  - A copy installed from this fork refreshes from `Free-Guy-IR/scripts`.
  - A copy installed from upstream refreshes from `PasarGuard/scripts`.
- **What the refresh does not do:** it replaces the libraries only. The script itself stays as installed.
- **Commands that replace the script:**
  - `install-script` reinstalls the script and the libraries, and restarts nothing.
    - Like every `pg-node` command, it first runs `sync_env_ssl_paths`, which can rewrite the SSL lines of a
      custom-named node's `.env`.
    - It creates `.env.lock`.
  - `update` reinstalls both from the copy's own fetch repository, then pulls the images and restarts the stack:
    the panel for `pasarguard update`, the node for `pg-node update`.
  - There is no `update-script` command.
- **Runs the panel triggers:** node-serviced runs `pg-node update --no-update-service` when the panel asks for a
  node update, and `pg-node geofiles`, `restart` and `core-update` for the matching panel actions. A panel action
  therefore reinstalls the node script from its fetch repository's `main`, and restarts the node.
- **One shared library directory:** every copy on a host uses the same library directory. If one copy fetches
  upstream and another the fork, the libraries flip between the two, depending on which copy ran last.
- **Compose overrides are ignored.** Every `pasarguard` and `pg-node` command passes `-f docker-compose.yml` to
  Compose, so `docker-compose.override.yml` is never read. This is upstream's behaviour, and the fork keeps it.
  - `update`, `restart`, `core-update` and every panel-triggered node action recreate the containers from the
    base file alone.
  - On a host whose override pins another image, or changes ports, volumes or environment, the first such
    command swaps the image or drops those settings.
  - `parity/FLEET_MIGRATION.md` step 1 finds such hosts. Moving the pin into `docker-compose.yml`, or teaching
    the scripts to read the override, is the owner's decision.

## The fleet as reported on 2026-09-25

This was reported by the second adversarial review. S1 has not re-checked it on any host; the migration's first
step re-inventories every host read-only.

| Host | What was found |
|---|---|
| Production panel 188.245 | `/usr/local/bin/pasarguard` has `fetch_repo="PasarGuard/scripts"`, so it runs upstream's libraries, refreshed from upstream `main` on every run. A push to the fork does not reach it. |
| Test host 46.224 | `pg-node` fetches upstream, while six other copies fetch the fork. All share one library directory, so its libraries flip between upstream and the fork. |

## What a push to the fork's main does

1. **Libraries:** every copy that fetches `Free-Guy-IR/scripts` picks up the new libraries on its next run, within
   minutes on nodes whose panel triggers node-serviced actions. There is no test step.
2. **Node scripts:** every fork node whose panel triggers a node update reinstalls `pg-node` itself from the fork's
   `main`, then restarts the node.
3. **Upstream copies:** copies that fetch `PasarGuard/scripts`, production's `pasarguard` among them, are not
   affected at all until they are migrated. See `parity/FLEET_MIGRATION.md`.

## Before every push to main

1. **Test the branch as a whole.** Push the branch, not `main`, and wait for its CI. On the test host, run the
   branch from a git checkout: `sudo bash ./pasarguard.sh ...` or `sudo bash ./pg-node.sh ...`. A checkout uses
   its own `lib/` and never refreshes.
2. **Test the mix the fleet will actually run.** Install the fork's current `main` on the test host, then put the
   branch's `lib/*.sh` into `/usr/local/lib/pasarguard-scripts/lib`. Run the installed commands with GitHub
   unreachable, for example `https_proxy=http://127.0.0.1:9`, so the refresh keeps those libraries.
   - The branch's skew check already covered this for the released v0.2.0 scripts, with their own unit tests
     plus a static function and variable scan.
3. **Merge and check.** Fast-forward `main` to the tested commit, check its CI, and watch one node through a
   panel-triggered update.
   - Pick a node whose compose override check in `parity/FLEET_MIGRATION.md` step 1 found no difference.
   - The update recreates the node from `docker-compose.yml` alone.

## Proposed change

- Bake the install commit into each installed copy.
- Refresh the libraries from `raw/<that commit>/lib/` instead of `raw/main/lib/`.
- Honour a `PASARGUARD_SCRIPTS_REF` override.

After that, a push to `main` would change no host until someone runs `install-script` or `update` there. This needs
its own spec and review.
