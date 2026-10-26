#!/usr/bin/env bash
# 单步入口：实现见 steps/40-server.sh（一键脚本 deploy.sh 用同一份实现）
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"
# shellcheck source=SCRIPTDIR/../steps/40-server.sh
. "${SELF_DIR}/../steps/40-server.sh"
case "${1:-}" in
  -h | --help)
    printf '用法：sudo bash %s

单步入口：%s
等价于 bash bin/deploy/deploy.sh --only %s
' "$0" '渲染服务端配置并重启 sing-box' 'server'
    exit 0
    ;;
  "") ;;
  *) usage_error "单步入口不接受参数：$1（部署流程请用 bin/deploy/deploy.sh）" ;;
esac
need_root
load_env_optional "${ENVFILE}" || true
server_run
