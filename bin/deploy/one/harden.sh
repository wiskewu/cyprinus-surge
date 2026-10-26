#!/usr/bin/env bash
# bin/deploy/one/harden.sh —— sing-box 降权与 systemd 沙箱。实现见 steps/55-harden.sh，
#   一键脚本 deploy.sh 以步骤名 harden 跑同一份代码。
#   随时可用 --check 复查、--revert 退回原来的单元文件。改完会重启服务，
#   配置校验失败就自动回滚。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"
# shellcheck source=SCRIPTDIR/../steps/55-harden.sh
. "${SELF_DIR}/../steps/55-harden.sh"

MODE=apply

usage() {
  cat <<'EOF'
用法：sudo bash bin/deploy/one/harden.sh [选项]

  （不带选项）    降权 + 沙箱：建 system 用户、收权限、重写 unit、重启并自检
  --minimal       只做降权（用户 + 三项能力），不加 Protect*/SystemCallFilter
  --check         只报告当前状态，不改任何东西
  --revert        用备份的 .orig 覆盖回去并重启
  -h, --help      显示帮助

改动前会把原 unit 备份到 /etc/systemd/system/sing-box.service.orig，
写入后重启；服务没起来或端口没监听就自动回滚。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --minimal) MODE=minimal ;;
    --check) MODE=check ;;
    --revert) MODE=revert ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "未知参数：$1"
      ;;
  esac
  shift
done

need_root

case "${MODE}" in
  check)
    harden_report
    ;;
  revert)
    [[ -f "${HARDEN_UNIT_ORIG}" ]] || die "没有备份 ${HARDEN_UNIT_ORIG}，无法回滚"
    harden_uninstall
    harden_report
    ;;
  *)
    HARDEN_PROFILE="${MODE}"
    harden_run
    harden_report
    ;;
esac
