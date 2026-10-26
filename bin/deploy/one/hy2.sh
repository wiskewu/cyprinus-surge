#!/usr/bin/env bash
# 单步入口：实现见 steps/35-hy2.sh（一键脚本 deploy.sh 用同一份实现）
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"
# shellcheck source=SCRIPTDIR/../steps/35-hy2.sh
. "${SELF_DIR}/../steps/35-hy2.sh"
case "${1:-}" in
  -h | --help)
    printf '用法：sudo bash %s

单步入口：%s
等价于 bash bin/deploy/deploy.sh --only %s
' "$0" 'Hysteria2 证书，可选' 'hy2'
    exit 0
    ;;
  "") ;;
  *) usage_error "单步入口不接受参数：$1（部署流程请用 bin/deploy/deploy.sh）" ;;
esac
need_root
load_env_optional "${ENVFILE}" || true
hy2_run
