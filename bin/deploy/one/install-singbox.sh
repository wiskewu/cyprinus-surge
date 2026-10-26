#!/usr/bin/env bash
# 单步入口：实现见 steps/20-install.sh（一键脚本 deploy.sh 用同一份实现）
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"
# shellcheck source=SCRIPTDIR/../steps/20-install.sh
. "${SELF_DIR}/../steps/20-install.sh"
case "${1:-}" in
  -h | --help)
    printf '用法：sudo bash %s

单步入口：%s
等价于 bash bin/deploy/deploy.sh --only %s
' "$0" '安装 sing-box 并写 systemd 单元' 'install'
    exit 0
    ;;
  "") ;;
  *) usage_error "单步入口不接受参数：$1（部署流程请用 bin/deploy/deploy.sh）" ;;
esac
need_root
install_run
