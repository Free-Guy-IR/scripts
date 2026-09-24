# Where this fork differs from PasarGuard/scripts

Upstream is `PasarGuard/scripts`. The fork last merged upstream `main` at `1fce1b1`.

`parity/ledger.tsv` holds a decision for every upstream item the fork has not merged: other branches, release
tags, and open pull requests. Each decision is pinned to that item's current SHA.

`.github/workflows/upstream-parity.yml` runs `tools/check-upstream-parity.sh` daily and on every push. The check
fails when upstream has a commit, branch, release tag or open pull request that is neither in the fork's history
nor in the ledger at its current SHA.

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
| b800167 | The systemd unit is written with mode 644. The pull request left it at 600 because of `umask 077`. |
| 2d6583b | `service-update` and the uninstall probe skip the update lock when neither the unit nor the binary exists, so nodes without node-serviced get no lock file. The systemd query itself stays inside the guarded transaction. |
| eef8e2a | See the list below. |

What eef8e2a changes:

- **What gets snapshotted:** `begin_node_service_transaction` takes the paths to snapshot.
  - `service-update` snapshots only the binary.
  - `service-install` and uninstall snapshot the unit and the binary.
  - Before this, a failed update restored `.env` and silently reverted edits made meanwhile by geofiles,
    `sync_env_ssl_paths` or `edit-env`.
- **How service-install rolls back `API_PORT`:** the write keeps before and after copies, taken under the `.env`
  lock at write time. The rollback restores the before copy only while `.env` still equals what the install
  wrote.
- **One `.env` lock:** every pg-node `.env` writer (`API_PORT`, `sync_env_ssl_paths`, geofiles, and `edit-env`
  for the whole editor session) takes a single flock on `$ENV_FILE.lock`.
- **Test mocks:** the pull request's tests used mocks that wrote `.env` from `install_node_service_script` and
  `ensure_env_exists`. They now match the real functions.
- **Test file:** `tests/test_node_service_env_interleaving.sh`.

## Version banner and standalone bundles

**What upstream 81237a3 and 152f09d do:** they print the commit a script runs from. The fork keeps the banner,
with two changes:

- **Honest report (25eb615):** `get_script_commit_sha` no longer asks GitHub for main's current head.
  - An installed copy keeps the script it was installed with, so main's head can be a commit it does not contain.
  - A copy without a baked SHA reports `unpinned (main)`.
  - A git HEAD is reported only for the root of a clean checkout of this repository, with `-dirty` when tracked
    files differ.
  - `tests/unit_lib_common.sh` follows the new contract.
- **Baking (4d3753b):** both standalone release workflows bake the release commit through
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
- `test_upstream_parity_check.sh`
- `test_fork_workflow_hardening.sh`
