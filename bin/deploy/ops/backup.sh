#!/usr/bin/env bash
# bin/deploy/ops/backup.sh —— 备份/恢复 sing-box 的全部东西（配置、密钥、证书、systemd 单元）。
# 用法： sudo bash bin/deploy/ops/backup.sh backup
#       sudo bash bin/deploy/ops/backup.sh list
#       sudo bash bin/deploy/ops/backup.sh restore /root/backups/sing-box-2026-10-19.tgz
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"
need_root
BK_DIR=/root/backups
install -d -m 700 "${BK_DIR}"

if [[ $# -eq 0 ]]; then
  if ui_has_tty; then
    actions=(
      "backup|新建备份"
      "list|列出已有备份"
      "restore|从指定备份恢复"
    )
    ui_menu "备份与恢复" "${actions[@]}"
    set -- "${UI_CHOICE}"
    if [[ "${UI_CHOICE}" == "restore" ]]; then
      ui_ask "备份文件路径"
      set -- restore "${UI_ANSWER}"
    fi
  else
    set -- backup
  fi
fi

case "${1:-backup}" in
  backup)
    f="${BK_DIR}/sing-box-$(date +%F-%H%M%S).tgz"
    tar -czf "${f}" -C / etc/sing-box etc/systemd/system/sing-box.service 2>/dev/null
    chmod 600 "${f}"
    log "已备份：${f}（$(du -h "${f}" | cut -f1)）"
    warn "这个包里有 REALITY 私钥，等同机器凭据，别放网盘/仓库。"
    ;;
  list)
    ls -lh "${BK_DIR}"/sing-box-*.tgz 2>/dev/null || printf '无备份\n'
    ;;
  restore)
    [[ -n "${2:-}" ]] && [[ -f "${2}" ]] || die "用法：bash bin/deploy/ops/backup.sh restore <文件>"
    tar -tzf "$2" >/dev/null || die "不是合法压缩包"
    systemctl stop sing-box 2>/dev/null || true
    tar -xzf "$2" -C /
    systemctl daemon-reload
    systemctl restart sing-box
    log "已恢复并重启：$2"
    systemctl is-active sing-box
    ;;
  *) die "用法：bash bin/deploy/ops/backup.sh backup|list|restore <文件>" ;;
esac
