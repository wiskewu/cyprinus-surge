#!/usr/bin/env bash
# entry.sh —— 唯一总入口。只做分发，各模块脚本可单独调用。
#
#   bash bin/entry.sh                     交互菜单
#   bash bin/entry.sh deploy --status     等价于 bash bin/deploy/deploy.sh --status
#   bash bin/entry.sh harden --check      等价于 bash bin/harden/harden.sh --check
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/common.sh
. "${SELF_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
用法：bash bin/entry.sh [子命令] [参数...]

  deploy    建节点：sing-box、REALITY、Hysteria2      → bin/deploy/deploy.sh
  device    设备凭据 add / list / rotate / revoke     → bin/deploy/device.sh
  share     设备分享链接（vless / hy2）                → bin/deploy/share.sh
  harden    SSH 加固                                  → bin/harden/harden.sh
  client    客户端密钥与免密登录                      → bin/harden/client.sh
  audit     验收：加固验收、服务端自检、客户端验收     → bin/harden/audit.sh 等
  rotate    凭据轮换：short_id、obfs、设备              → bin/deploy/rotate.sh
  ops       备份、监控、端口跳跃                      → bin/deploy/ops/*.sh
  -h        显示本帮助

不带参数且为交互终端时进入菜单。子命令后接 --help 可看该模块自己的用法。
EOF
}

deploy() { exec bash "${SELF_DIR}/deploy/deploy.sh" "$@"; }
device() { exec bash "${SELF_DIR}/deploy/device.sh" "$@"; }
share() { exec bash "${SELF_DIR}/deploy/share.sh" "$@"; }
harden() { exec bash "${SELF_DIR}/harden/harden.sh" "$@"; }
client() { exec bash "${SELF_DIR}/harden/client.sh" "$@"; }

audit() {
  case "${1:-}" in
    ----*) exec bash "${SELF_DIR}/harden/audit.sh" ;;
  esac
  if [[ $# -eq 0 ]]; then
    ui_menu "选择验收对象" \
      "harden|SSH 加固验收（只读）" \
      "server|服务端自检：进程、监听、日志" \
      "selfcheck|sing-box 沙箱自查" \
      "client|客户端代理验收"
    case "${UI_CHOICE}" in
      harden) exec bash "${SELF_DIR}/harden/audit.sh" ;;
      server) exec bash "${SELF_DIR}/deploy/check/server.sh" ;;
      selfcheck) exec bash "${SELF_DIR}/deploy/check/selfcheck.sh" ;;
      client) exec bash "${SELF_DIR}/deploy/client/verify.sh" ;;
    esac
  fi
  case "$1" in
    harden)
      shift
      exec bash "${SELF_DIR}/harden/audit.sh" "$@"
      ;;
    server)
      shift
      exec bash "${SELF_DIR}/deploy/check/server.sh" "$@"
      ;;
    selfcheck)
      shift
      exec bash "${SELF_DIR}/deploy/check/selfcheck.sh" "$@"
      ;;
    client)
      shift
      exec bash "${SELF_DIR}/deploy/client/verify.sh" "$@"
      ;;
    *) usage_error "未知的验收对象：$1" ;;
  esac
}

ops() {
  if [[ $# -eq 0 ]]; then
    ui_menu "选择运维动作" \
      "backup|备份、列出、恢复" \
      "monitor|探针报告" \
      "port-hop|Hysteria2 端口跳跃"
    case "${UI_CHOICE}" in
      backup) exec bash "${SELF_DIR}/deploy/ops/backup.sh" ;;
      monitor) exec bash "${SELF_DIR}/deploy/ops/monitor.sh" ;;
      port-hop) exec bash "${SELF_DIR}/deploy/one/port-hop.sh" ;;
    esac
  fi
  case "$1" in
    backup)
      shift
      exec bash "${SELF_DIR}/deploy/ops/backup.sh" "$@"
      ;;
    monitor)
      shift
      exec bash "${SELF_DIR}/deploy/ops/monitor.sh" "$@"
      ;;
    port-hop)
      shift
      exec bash "${SELF_DIR}/deploy/one/port-hop.sh" "$@"
      ;;
    *) usage_error "未知的运维动作：$1" ;;
  esac
}

case "${1:-}" in
  deploy)
    shift
    deploy "$@"
    ;;
  device)
    shift
    device "$@"
    ;;
  share)
    shift
    share "$@"
    ;;
  harden)
    shift
    harden "$@"
    ;;
  client)
    shift
    client "$@"
    ;;
  audit)
    shift
    audit "$@"
    ;;
  ops)
    shift
    ops "$@"
    ;;
  -h | --help) usage ;;
  "")
    ui_menu "请选择要做的事" \
      "deploy|部署节点：系统初始化到 Hysteria2" \
      "harden|SSH 加固：仅公钥登录、限速、fail2ban" \
      "device|设备凭据：新增、轮换、吊销、渲染" \
      "share|设备分享链接：vless / hy2" \
      "audit|验收：加固、服务端、客户端" \
      "ops|运维：备份、监控、端口跳跃" \
      "client|客户端密钥与免密登录"
    case "${UI_CHOICE}" in
      deploy) deploy ;;
      harden) harden ;;
      device) device ;;
      share) share ;;
      audit) audit ;;
      ops) ops ;;
      client) client ;;
    esac
    ;;
  *) usage_error "未知子命令：$1" ;;
esac
