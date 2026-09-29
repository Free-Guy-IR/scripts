# Where this fork differs from PasarGuard/scripts

Upstream is `PasarGuard/scripts`. The fork last merged upstream `main` at `1fce1b1`.

`parity/ledger.tsv` holds a decision for every upstream item the fork has not merged: other branches, release
tags, and open pull requests. Each decision is pinned to that item's current SHA.

`.github/workflows/upstream-parity.yml` runs `tools/check-upstream-parity.sh` daily and on every push. The check
fails when upstream has a commit, branch, release tag or open pull request that is neither in the fork's history
nor in the ledger at its current SHA.

The check trusts nothing it did not see itself:

- It compares every local `refs/remotes/upstream/*` and `refs/upstream-tags/*` ref with `git ls-remote`, so a
  partial fetch (`git fetch upstream main`), a stale fetch or an unpruned ref fails and prints the fetch command.
- Without `OPEN_PRS_FILE` it lists the open pull requests from the GitHub API itself, reads every page, and fails
  when the API is unreachable or answers with anything but a list. The output says where the list came from.
  `OPEN_PRS_FILE` exists for the tests; a parity claim must come from a run without it.

To check parity from a local clone:

```
git fetch --prune --no-tags upstream '+refs/heads/*:refs/remotes/upstream/*' '+refs/tags/*:refs/upstream-tags/*'
bash tools/check-upstream-parity.sh
```

This file lists every upstream-owned file the fork changes, and why.

## Repository and image names

These files point at the fork's own repositories and images:

| Files | What changes |
|---|---|
| `pasarguard.sh`, `pg-node.sh`, `install_core.sh` | `Free-Guy-IR/scripts`, `Free-Guy-IR/panel` and `Free-Guy-IR/node` |
| `lib/common.sh` | `Free-Guy-IR/scripts` |
| `iran-sanction/*.sh` and their READMEs | the same repositories |
| `docker-compose/*.yml` | the `ghcr.io/free-guy-ir/panel` and `ghcr.io/free-guy-ir/node` images |
| `README.md`, `docs/offline-and-sanctions.md` | the fork's install URLs, releases and panel image |
| `tests/unit_pasarguard.sh` | the image name it expects |
| the two standalone release workflows | fetch the fork's panel and node `.env.example` and compose file |

Specific changes in `pasarguard.sh`:

- `list_pasarguard_app_services` also recognises `ghcr.io/free-guy-ir/panel`, so backup and restore stop and
  start the fork's panel (ba26802).
- `resolve_remote_commit_sha` defaults to `Free-Guy-IR/scripts` in `lib/common.sh` and `install_core.sh`.

## Fork features

- **Subscription page install:** `pasarguard.sh install --sub-template` runs `install_subscription_template` to
  install the subscription page.
- **Host devices and L2TP:** `pg-node.sh` gets `l2tp-enable` and `prepare_host_devices`, which set up TUN, PPP
  and IP forwarding for the OpenVPN and L2TP cores (086c0a6). Tests for them are in `tests/unit_pgnode.sh`.

## Upstream pull request #25, "Harden node-serviced updates"

**Status:** open and unmerged upstream. The fork squash-ported it from head `4c54ca1` as f32806d. It adds about
1,400 lines to `pg-node.sh`, and changes `lib/common.sh`, `lib/github.sh`, `tests/run_all.sh`,
`tests/unit_lib_common.sh`, `tests/unit_lib_github.sh` and `tests/unit_pgnode.sh`. It also adds
`tests/test_node_service_transaction_guard.sh` and `tests/test_node_service_readiness_tls.sh`.

**What it does:** it verifies the downloaded node-serviced archive against the release's `checksums.txt`, swaps
the binary in atomically, and rolls back after a failed restart or readiness check.

**How the fork's copy differs from the pull request:**

| Commit | Change |
|---|---|
| 2cf37a6 | The systemd unit is written with mode 644. The pull request left it at 600 because of `umask 077`. |
| f4e8aa1 | `service-update` and the uninstall probe skip the update lock when neither the unit nor the binary exists, so nodes without node-serviced get no lock file. The systemd query itself stays inside the guarded transaction. |
| e190d3d | See the list below. |

What e190d3d changes:

- **What gets snapshotted:** `begin_node_service_transaction` takes the paths to snapshot.
  - `service-update` snapshots only the binary.
  - `service-install` and uninstall snapshot the unit and the binary.
  - Before this, a failed update restored `.env` and silently reverted edits made meanwhile by geofiles,
    `sync_env_ssl_paths` or `edit-env`.
- **How service-install rolls back `API_PORT`:** the write keeps before and after copies, taken under the `.env`
  lock at write time. The rollback restores the before copy only while `.env` still equals what the install
  wrote.
- **One `.env` lock:** every pg-node `.env` writer takes a single flock on `$ENV_FILE.lock`: `API_PORT`,
  `sync_env_ssl_paths`, geofiles, core-update and install. `tests/test_env_writes_hold_lock.sh` fails on any
  `.env` write in `pg-node.sh` outside the lock.
  - The analyser, `tests/env_lock_analyzer.py`, treats every line that names `.env` as a write unless it is a
    known read. It models conditional acquires, and flags a `curl` without `--max-time` while the lock is held.
  - `tests/fixtures/env_lock_probes.txt` holds one unlocked write per form the reviews found. The analyser must
    flag each of them before it checks `pg-node.sh`.
  - `begin_node_service_transaction` refuses an empty path list and refuses `.env`. Changes to `.env` go
    through the lock, never through a snapshot and restore.
- **Stage, then apply under the lock:** core-update and install stage their downloads and certificate first,
  and change the live files only after taking the lock. This covers the Xray-core files, the certificate and
  key, `.env` and the compose file.
  - A lock timeout, a failed download or a rejected prompt therefore changes nothing, and the staging directory
    is removed on exit.
  - No network call and no prompt runs while the lock is held.
  - Before this, a failed core-update had already replaced the core, and a reinstall that stopped on a busy port
    had already replaced the certificate.
  - The holder writes its pid, start time and command into the lock file. A command that times out on the lock
    names that holder in its error.
  - `edit-env` does not hold the lock while the editor is open. It edits a copy, then saves it under the lock
    only if `.env` is still what the editor was opened on. Otherwise it refuses and keeps the admin's copy next to
    `.env`.
  - A kept copy is named `..env.edit-*`. It holds the whole `.env`, including `API_KEY`, with mode 0600.
    Nothing ever deletes it: the admin removes it after merging by hand.
- **Test mocks:** the pull request's tests used mocks that wrote `.env` from `install_node_service_script` and
  `ensure_env_exists`. They now match the real functions.
- **Test file:** `tests/test_node_service_env_interleaving.sh`.

## Small fixes to upstream functions

- **`is_port_occupied` (69fde31):** it reads the port list from a here-string instead of `echo | grep -q`.
  - Under `set -o pipefail`, `echo` could take SIGPIPE after `grep -q` had matched and exited, and the match
    became a miss.
  - `tests/unit_pgnode.sh` runs with `pipefail`, which is why "port 80 is busy" failed now and then.
  - The scripts themselves do not set `pipefail`, so installs were not affected.

## Version banner and standalone bundles

**What upstream 81237a3 and 152f09d do:** they print the commit a script runs from. The fork keeps the banner,
with two changes:

- **Honest report (2f10e0f):** `get_script_commit_sha` no longer asks GitHub for main's current head.
  - An installed copy keeps the script it was installed with, so main's head can be a commit it does not contain.
  - A copy without a baked SHA reports `unpinned (main)`.
  - A git HEAD is reported only for the root of a clean checkout of this repository, with `-dirty` when tracked
    files differ.
  - `tests/unit_lib_common.sh` follows the new contract.
- **Baking (4add693):** both standalone release workflows bake the release commit through
  `tools/bake-script-commit.sh`.
  - The tool rewrites only the `SCRIPT_COMMIT_SHA=` assignment line.
  - Upstream's `sed` over every `.sh` file also rewrote the sentinel comparisons, so a bundle never reported the
    commit it was built from.

## Tests only the fork has

These tests are in `tests/`. `.github/workflows/fork-regression-tests.yml` runs all of them except
`test_upstream_parity_check.sh`, which runs in `.github/workflows/upstream-parity.yml`:

- `test_fresh_dump_in_archive.sh`
- `test_restore_failure_restarts_panel.sh`
- `test_fork_script_repo.sh`
- `test_node_serviced_checksum.sh`
- `test_fork_panel_image_detection.sh`
- `test_node_service_unit_mode.sh`
- `test_node_service_lock_only_when_installed.sh`
- `test_standalone_commit_bake.sh`
- `test_node_service_env_interleaving.sh`
- `test_env_writes_hold_lock.sh`
- `test_upstream_parity_check.sh`
- `test_fork_workflow_hardening.sh`
