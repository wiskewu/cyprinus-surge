#!/usr/bin/env bash
# 单步入口：实现见 steps/40-server.sh（一键脚本 deploy.sh 用同一份实现）
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"
# shellcheck source=SCRIPTDIR/../steps/40-server.sh
. "${SELF_DIR}/../steps/40-server.sh"
OPT_DRY_RUN=0

usage() {
  cat <<EOF
用法：sudo bash $0 [选项]

  （不带选项）   用 deploy.env 渲染服务端配置，校验后覆盖并重启 sing-box
  --dry-run      只渲染到 data/config.preview.json，不改系统、不重启
  -h, --help     显示帮助

输出路径用 OUT 覆盖（默认 data/config.preview.json）。
等价于 bash bin/deploy/deploy.sh --only server。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) OPT_DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "未知参数：$1（--help 看用法）" ;;
  esac
  shift
done

need_root
[[ "${OPT_DRY_RUN}" == "1" ]] && export DRY_RUN=1
server_run
