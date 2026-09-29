#!/usr/bin/env bash
set -uo pipefail

SCRIPTS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_FILES=(pg-node.sh lib/common.sh lib/system.sh lib/docker.sh lib/github.sh iran-sanction/pg-node-standalone.sh iran-sanction/mirror.sh)
PANEL_LIBS=(lib/env.sh lib/pasarguard-backup.sh lib/pasarguard-restore.sh)
FAILURES=0

cd "$SCRIPTS_ROOT" || exit 1

sourced="$(sed -n 's|^source "\$SHARED_LIB_DIR/\([A-Za-z0-9_-]*\.sh\)"$|lib/\1|p' pg-node.sh | sort | tr '\n' ' ')"
if [ "$sourced" = "lib/common.sh lib/docker.sh lib/github.sh lib/system.sh " ]; then
    echo "PASS: pg-node.sh sources exactly the libraries this test scans as node files"
else
    echo "FAIL: pg-node.sh sources '$sourced'; update NODE_FILES and PANEL_LIBS in this test"
    FAILURES=$((FAILURES + 1))
fi

for lib in lib/*.sh; do
    case " ${NODE_FILES[*]} ${PANEL_LIBS[*]} " in
    *" $lib "*) ;;
    *)
        echo "FAIL: $lib is neither a node file nor a panel library in this test"
        FAILURES=$((FAILURES + 1))
        ;;
    esac
done

python3 tests/env_lock_analyzer.py \
    --probes tests/fixtures/env_lock_probes.txt \
    --probe-panel-lib tests/fixtures/env_lock_panel_lib.txt "${PANEL_LIBS[@]}" \
    --panel-lib "${PANEL_LIBS[@]}" \
    --node "${NODE_FILES[@]}" || FAILURES=$((FAILURES + 1))

[ "$FAILURES" -eq 0 ]
