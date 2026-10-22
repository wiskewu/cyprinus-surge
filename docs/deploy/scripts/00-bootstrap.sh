#!/usr/bin/env bash
# 单步入口：实现见 steps/10-system.sh（一键脚本 deploy.sh 用同一份实现）
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$SELF_DIR/lib.sh"
# shellcheck source=SCRIPTDIR/steps/10-system.sh
. "$SELF_DIR/steps/10-system.sh"
need_root
system_run
