#!/usr/bin/env bash
# bin/deploy/rotate.sh —— 凭据轮换：REALITY short_id、Hy2 obfs 密码、全部设备凭据。
#
#   sudo bash bin/deploy/rotate.sh short-id          换 REALITY short_id
#   sudo bash bin/deploy/rotate.sh obfs              换 Hysteria2 obfs 密码
#   sudo bash bin/deploy/rotate.sh device <名字>     换单台设备凭据
#   sudo bash bin/deploy/rotate.sh devices           换全部设备凭据
#   sudo bash bin/deploy/rotate.sh all               上面三项依次执行
#
# 共同约定：
#   --dry-run  只打印将要改什么，不落盘
#   --yes      不确认，交给脚本调用
# 轮换会立刻让旧客户端配置失效，执行后必须重新渲染并分发客户端配置。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "${SELF_DIR}/lib.sh"

ACTION=""
TARGET=""
DRY=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes) ASSUME_YES=1 ;;
    short-id | obfs | devices | all) ACTION="$1" ;;
    device)
      ACTION=device
      shift
      TARGET="${1:?device 需要名字}"
      ;;
    -h | --help)
      cat <<'EOF'
用法：sudo bash bin/deploy/rotate.sh <动作> [选项]

  short-id          重新生成 REALITY short_id
  obfs              重新生成 Hysteria2 obfs 密码（需要 ENABLE_HY2=1）
  device <名字>     轮换单台设备凭据
  devices           轮换全部设备凭据
  all               依次执行 short-id、obfs、devices

  --dry-run         只打印计划
  --yes             不确认

执行后客户端配置全部失效，需要重新渲染并分发。
EOF
      exit 0
      ;;
    *) usage_error "未知参数：$1" ;;
  esac
  shift
done

if [[ -z "${ACTION}" ]]; then
  if ui_has_tty; then
    actions=(
      "short-id|换 REALITY short_id"
      "obfs|换 Hysteria2 obfs 密码"
      "devices|换全部设备凭据"
      "all|三项依次执行"
    )
    ui_menu "凭据轮换" "${actions[@]}"
    ACTION="${UI_CHOICE}"
  else
    usage_error "非交互环境请给出动作：short-id|obfs|device <名字>|devices|all"
  fi
fi

need_root
load_env_optional "${ENVFILE}" || die "找不到 ${ENVFILE}，先完成部署"

confirm() {
  [[ "${ASSUME_YES}" == 1 ]] && return 0
  ui_confirm "$1，轮换后旧客户端配置立刻失效。继续" n
}

new_short_id() { openssl rand -hex 8; }
new_obfs() { openssl rand -base64 18 | tr -d '\n/+=' | cut -c1-16; }

# 写回 deploy.env：存在则替换，不存在则追加
env_set_key() { # $1=键 $2=值
  local k="$1" v="$2" f="${ENVFILE}"
  if grep -q "^${k}=" "${f}"; then
    sed -i "s|^${k}=.*|${k}=\"${v}\"|" "${f}"
  else
    printf '%s="%s"\n' "${k}" "${v}" >>"${f}"
  fi
  chmod 600 "${f}"
}

rotate_short_id() {
  local old new
  old="${SHORT_ID:-}"
  new="$(new_short_id)"
  printf 'REALITY short_id：%s → %s\n' "${old:-空}" "${new}"
  if [[ "${DRY}" == 1 ]]; then
    return 0
  fi
  env_set_key SHORT_ID "${new}"
  SHORT_ID="${new}"
}

rotate_obfs() {
  local old new
  if [[ "${ENABLE_HY2:-0}" != "1" ]]; then
    warn "ENABLE_HY2 不是 1，跳过 obfs"
    return 0
  fi
  old="${OBFS_PASSWORD:-}"
  new="$(new_obfs)"
  printf 'Hy2 obfs 密码：%s → %s\n' "${old:+已设置}" "${new}"
  if [[ "${DRY}" == 1 ]]; then
    return 0
  fi
  env_set_key OBFS_PASSWORD "${new}"
  OBFS_PASSWORD="${new}"
}

rotate_devices() {
  local only="${1:-}" names n
  names="$(awk '!/^[[:space:]]*#/ && NF >= 2 {print $1}' "${DEVICES_LIST}")"
  [[ -n "${names}" ]] || die "设备名单为空：${DEVICES_LIST}"
  if [[ -n "${only}" ]]; then
    printf '将轮换设备：%s\n' "${only}"
  else
    printf '将轮换全部设备：%s\n' "$(printf '%s' "${names}" | paste -sd' ' -)"
  fi
  if [[ "${DRY}" == 1 ]]; then
    return 0
  fi
  if [[ -n "${only}" ]]; then
    bash "${SELF_DIR}/device.sh" rotate "${only}"
  else
    for n in ${names}; do
      bash "${SELF_DIR}/device.sh" rotate "${n}"
    done
  fi
}

# 轮换后重新渲染服务端配置并重启；返回非零时提示旧配置已失效
apply_server() {
  [[ "${DRY}" == 1 ]] && return 0
  log "重渲染服务端配置"
  bash "${SELF_DIR}/one/server.sh" >/tmp/rotate-render.log 2>&1 || {
    warn "重渲染失败，见 /tmp/rotate-render.log。配置已改，必须修好后重跑一步"
    return 1
  }
  systemctl is-active --quiet sing-box || die "sing-box 未运行，检查 journalctl -u sing-box -n 30"
  log "服务已按新凭据重启"
}

case "${ACTION}" in
  short-id)
    confirm "即将轮换 REALITY short_id" || exit 0
    rotate_short_id
    apply_server
    ;;
  obfs)
    confirm "即将轮换 Hysteria2 obfs 密码" || exit 0
    rotate_obfs
    apply_server
    ;;
  device)
    confirm "即将轮换设备 ${TARGET}" || exit 0
    rotate_devices "${TARGET}"
    ;;
  devices)
    confirm "即将轮换全部设备凭据" || exit 0
    rotate_devices
    ;;
  all)
    confirm "即将轮换 short_id、obfs 与全部设备" || exit 0
    rotate_short_id
    rotate_obfs
    apply_server
    rotate_devices
    ;;
  *) usage_error "未知动作：${ACTION}" ;;
esac

cat <<EOF

轮换完成。仍有三步收尾：
  1) 重新渲染并分发客户端：bash ${SELF_DIR}/device.sh render <名字>（或 --all 平台）
  2) 旧客户端配置已失效，让对方删除后重新导入
  3) 若目标是应对泄露，确认旧凭据所在的备份与聊天记录一并清理
EOF
