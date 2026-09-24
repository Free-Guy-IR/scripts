# How a push to main reaches installed hosts

## What happens today

- **Libraries:** an installed `pasarguard` or `pg-node` refreshes every `lib/*.sh` from
  `https://github.com/Free-Guy-IR/scripts/raw/main/lib/` each time it runs (`bootstrap_pasarguard_shared_libs`,
  `bootstrap_pg_node_shared_libs`).
  - node-serviced runs `pg-node update`, `geofiles`, `restart` and `core-update` whenever the panel asks it to.
  - So a push to `main` changes the libraries on every such host within minutes, with no test deployment first.
- **The scripts themselves:** `pasarguard.sh` and `pg-node.sh` change only when someone runs `update`,
  `install-script` or `update-script` on that host.
- **No override:** there is no ref override. The repository and `main` are hardcoded in both bootstrap functions
  and in `github_raw_url`.

## Before every push to main

1. **Test the branch as a whole.** Push the branch, not `main`, and wait for its CI. Then run the branch on the
   test host from a git checkout: `sudo bash ./pasarguard.sh ...` or `sudo bash ./pg-node.sh ...`. A checkout
   uses its own `lib/` and never refreshes from `main`.
2. **Test the mix the fleet will actually run: old installed scripts with the new libraries.** Install the
   currently released scripts on the test host. Put the branch's `lib/*.sh` in
   `/usr/local/lib/pasarguard-scripts/lib`. Then run the installed commands with GitHub unreachable, for
   example `https_proxy=http://127.0.0.1:9`. The best-effort refresh then keeps those libraries.
   - The branch's tests cover this mix only statically.
   - They also cover it with the old releases' own unit tests (see the S1-fix skew run).
3. **Merge only after both pass.** Fast-forward `main` to the tested commit, then check CI on `main`.

## Proposed change to the rollout

- **Pin installed copies to their install commit:**
  - At install, bake the commit an installed copy was fetched from into its `SCRIPT_COMMIT_SHA` line.
  - Have the per-run refresh fetch `raw/<that commit>/lib/` instead of `raw/main/lib/`.
- **Add an override:** honour a `PASARGUARD_SCRIPTS_REF` override in install and update, defaulting to `main`.
- **Effect:**
  - A push to `main` would no longer change any installed host by itself.
  - Rollout would be `pasarguard update-script` or `pg-node update-script`: the test host first, then the fleet.
  - The version banner of an installed copy would show a real commit instead of `unpinned (main)`.
- **Transition:** hosts that already have a copy keep refreshing from `main` until they update once.
