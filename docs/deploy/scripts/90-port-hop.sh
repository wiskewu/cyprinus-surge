#!/usr/bin/env bash
# 单步入口：实现见 steps/60-porthop.sh（一键脚本 deploy.sh 用同一份实现）
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "${SELF_DIR}/lib.sh"
# shellcheck source=SCRIPTDIR/steps/60-porthop.sh
. "${SELF_DIR}/steps/60-porthop.sh"
need_root
load_env "${ENVFILE}" 2>/dev/null || true
porthop_run
