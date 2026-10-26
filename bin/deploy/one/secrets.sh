#!/usr/bin/env bash
# 单步入口：实现见 steps/30-secrets.sh（一键脚本 deploy.sh 用同一份实现）
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"
# shellcheck source=SCRIPTDIR/../steps/30-secrets.sh
. "${SELF_DIR}/../steps/30-secrets.sh"
OPT_OVERWRITE=0
OPT_ROTATE_SECRETS=0

usage() {
  cat <<EOF
用法：sudo bash $0 [选项]

  （不带选项）     ${ENVFILE} 不存在时生成；已存在则保留并退出
  --overwrite      重新生成 deploy.env / client.env（设备名单与 REALITY 密钥沿用）
  --rotate-secrets 换掉所有客户端可见的密钥：REALITY 密钥对、short_id 与
                   HY2 混淆密码。已导出的客户端配置立即失效，需逐台重新 export
  -h, --help       显示帮助

需要的材料：启用 Hysteria2 时要有入口域名、Cloudflare API Token 与邮箱。
等价于 bash bin/deploy/deploy.sh --only secrets（该入口用 --overwrite / --rotate-secrets）。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --overwrite) OPT_OVERWRITE=1 ;;
    --rotate-secrets)
      OPT_ROTATE_SECRETS=1
      OPT_OVERWRITE=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "未知参数：$1（--help 看用法）" ;;
  esac
  shift
done

need_root
if [[ -f "${ENVFILE}" ]] && [[ "${OPT_OVERWRITE}" != "1" ]]; then
  log "${ENVFILE} 已存在，保留原样（要重建：sudo bash $0 --overwrite）"
  exit 0
fi
secrets_run
