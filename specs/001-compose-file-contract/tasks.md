# Tasks: Compose-File Contract

**Input**: design documents in `specs/001-compose-file-contract/`

**Tests**: required (constitution I, test-first). The RED test is committed alone before the fix.

## Phase 1: Setup

- [ ] T001 Record upstream PR #34 (be8f734d5838ca284c8db901234d52905e5dd61a) as deferred in parity/ledger.tsv and confirm `bash tools/check-upstream-parity.sh` exits 0, as its own commit

## Phase 2: Foundational (RED)

- [ ] T002 Write tests/test_compose_override_honoured.sh: a recording `docker` stand-in on PATH; app dirs with a base file naming image A and an override naming image B; runs the real `restart_command -n`, `update` pull, `up`, `down`, `logs`, status and service lookups of pasarguard.sh and pg-node.sh; checks each recorded Compose call loads `-f <base> -f <override>` in that order, that calls without an override are unchanged, that `-p` presence is unchanged, the override name order of the contract, a path with spaces, the old-script use of `compose_up`/`compose_down` with only `COMPOSE`, `COMPOSE_FILE` and `APP_NAME` set, the new-script-with-old-library refusal, the install notice, and, when a Compose binary is available, that Compose resolves image B from the recorded arguments; commit it alone and record its failing run on the parent

## Phase 3: User Story 1 and 2 - restarts and updates keep pinned images (P1)

- [ ] T003 [US1] Add `compose_override_file`, `compose_cmd` and `compose_override_notice` to lib/docker.sh and route `compose_up`, `compose_down`, `compose_logs`, `compose_logs_follow` through `compose_cmd` per contracts/compose-invocation.md
- [ ] T004 [US1] Replace every direct `$COMPOSE -f "$COMPOSE_FILE"` / `$COMPOSE -f $COMPOSE_FILE` call in pasarguard.sh with `compose_cmd`, keeping each call's remaining arguments and its `-p` usage
- [ ] T005 [US2] Replace every direct Compose call in pg-node.sh the same way

## Phase 4: User Story 3 - mixed versions (P2)

- [ ] T006 [US3] After sourcing the libraries in pasarguard.sh and pg-node.sh, exit 1 with `Shared library <dir>/docker.sh is older than this script` when `compose_cmd` is not defined

## Phase 5: User Story 4 - install notice (P3)

- [ ] T007 [US4] Call `compose_override_notice` after the image is written in pasarguard.sh `install_pasarguard`, iran-sanction/pasarguard-standalone.sh `install_pasarguard`, pg-node.sh `install_node` and iran-sanction/pg-node-standalone.sh `install_node`

## Phase 6: Polish

- [ ] T007a [US4] FR-009: tests/test_restore_keeps_destination_override.sh (RED), then exclude the four override names from the ordinary non-SQLite restore's app-directory sync in lib/pasarguard-restore.sh and say when the backup held one
- [ ] T008 [P] Run tests/test_compose_override_honoured.sh and tests/test_restore_keeps_destination_override.sh in .github/workflows/fork-regression-tests.yml
- [ ] T009 [P] Record the lib/docker.sh and call-site divergence in parity/DIVERGENCES.md
- [ ] T010 shellcheck every changed shell file; run tests/run_all.sh and every tests/test_*.sh through tests/run_isolated.sh
- [ ] T011 An independent verifier re-runs the RED test on the parent and on the final head
- [ ] T012 Fresh adversarial reviewers review the final diff until a round finds nothing new
- [ ] T013 3/3 gate on the final head, push, and CI on the exact SHA

## Dependencies

T001 is independent. T002 precedes T003 to T007. T003 precedes T004 to T007. T008 to T010 follow
T007. T011 to T013 follow T010.

## Parallel Opportunities

T004 and T005 touch different files; T008 and T009 touch different files.

## Implementation Strategy

MVP is T003 to T005: the library change alone already fixes old installed scripts' restart and
update. T006 and T007 harden mixed versions and installs.
