#!/usr/bin/env bash
# 单步入口：实现见 steps/10-system.sh（一键脚本 deploy.sh 用同一份实现）
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"
# shellcheck source=SCRIPTDIR/../steps/10-system.sh
. "${SELF_DIR}/../steps/10-system.sh"
case "${1:-}" in
  -h | --help)
    printf '用法：sudo bash %s

单步入口：%s
等价于 bash bin/deploy/deploy.sh --only %s
' "$0" '系统初始化：依赖、BBR、swap、时间同步、SSH 加固、防火墙' 'system'
    exit 0
    ;;
  "") ;;
  *) usage_error "单步入口不接受参数：$1（部署流程请用 bin/deploy/deploy.sh）" ;;
esac
need_root
system_run
