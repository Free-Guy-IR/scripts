# Keeping the upstream parity check alive

`.github/workflows/upstream-parity.yml` runs daily, but GitHub may stop running it without any error anyone sees:

- **Forks:** workflows in a fork stay off until someone enables them in the Actions tab.
- **Inactive repositories:** GitHub disables scheduled workflows after 60 days without activity.
- **Silence:** a disabled or never-enabled schedule produces no failure, so a red check can never appear.

A check that stops running looks exactly like a check that passes. It therefore needs a watchdog outside GitHub.

## Plan (not installed yet)

The watchdog is a job in the async-review daemon (launchd `com.freeguy.async-review`, every 15 minutes, on the
owner's Mac). Findings it writes to `~/.claude/pending-review-findings.md` are already injected into every session.

1. **Ask GitHub for the latest parity run on `main`:**

   `GET /repos/Free-Guy-IR/scripts/actions/workflows/upstream-parity.yml/runs?branch=main&per_page=1`

   Use the Free-Guy-IR token from the keychain.
2. **Alert, by adding one finding and one KG observation, when any of these holds:**
   - there is no run at all;
   - the latest run's `created_at` is more than 36 hours old;
   - the latest run finished with anything other than `success`.
3. **Check the workflow itself:** `GET /repos/Free-Guy-IR/scripts/actions/workflows/upstream-parity.yml` must report
   `state: active`. Any other state raises the same alert with the state in the message.
4. **Stay quiet otherwise.** Do not repeat an alert for the same run id; open it again only when a newer run is
   also stale or failing.
5. **Cover the other forks the same way:**
   - panel, node, node_bridge_py, core-kit, wireguard-config-kit and subscription-template, once each has an
     upstream-parity workflow;
   - the kits, with the same workflow endpoint and a 7-day limit for kits with no schedule.

The fleet dashboard on the German server could run the same probe instead. It already polls and alerts, but it has
no GitHub token today, so the async-review daemon is the smaller change.
