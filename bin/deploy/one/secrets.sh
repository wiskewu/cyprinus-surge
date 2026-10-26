#!/usr/bin/env bash
# 单步入口：实现见 steps/30-secrets.sh（一键脚本 deploy.sh 用同一份实现）
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"
# shellcheck source=SCRIPTDIR/../steps/30-secrets.sh
. "${SELF_DIR}/../steps/30-secrets.sh"
need_root
if [[ -f "${ENVFILE}" ]] && [[ "${FORCE:-0}" != "1" ]]; then
  log "${ENVFILE} 已存在，保留原样（要重建：sudo FORCE=1 bash $0）"
  exit 0
fi
secrets_run
