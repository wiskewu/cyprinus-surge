#!/usr/bin/env bash
# device.sh —— 设备凭据管理。每台设备一份独立凭据，删一行 = 吊销那台。
#
# 用法：
#   sudo bash device.sh list
#   sudo bash device.sh add laptop [desktop|android|ios]
#   sudo bash device.sh rotate laptop
#   sudo bash device.sh revoke laptop
#
# 做的事：改 devices.list → 重渲染服务端配置 → 重新渲染该设备的客户端 JSON。
# 不自己实现任何 sing-box 逻辑，渲染一律走现有脚本，所以不会和模板漂移。
#
# 真相源是 $DEVICES_LIST（默认 /etc/sing-box/devices.list），建议纳入 git。
# 一台设备一个凭据，同时当 VLESS uuid 与 Hysteria2 password——吊销因此是原子的。
#
# 在【服务器】上跑：它就地改名单、重渲染服务端、重渲染该设备的客户端 JSON。
# 本地生成客户端配置请用 50-render-client.sh（默认输出到 ./data）。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"
need_root

CLIENT_OUT="${CLIENT_OUT:-$DEPLOY_DIR/clients}"
VALID_PLATFORMS="desktop android ios"

# 子脚本（50-render-client.sh / 30-render-server.sh）靠环境变量找这些文件，必须导出
export DEPLOY_DIR ENVFILE CLIENT_ENV DEVICES_LIST

usage() {
  cat <<EOF
用法：sudo bash device.sh <命令> [参数]

  list                      列出设备名单
  add <名字> [平台]         新增一台并生成凭据（平台默认 desktop）
  rotate <名字>             换掉凭据，旧配置立刻失效
  revoke <名字>             删除设备，立刻失效
  render <名字>             只重新渲染该设备的客户端配置，不动服务端

环境变量：
  DEVICES_LIST  设备名单路径（默认 /etc/sing-box/devices.list）
  CLIENT_OUT    客户端配置输出目录（默认 $DEPLOY_DIR/clients）
  CLIENT_ENV    客户端环境文件（默认 /etc/sing-box/client.env）

注意：add / rotate / revoke 都会重启 sing-box。当前有活跃会话时，
连接不会断（规则已建立），但新连接会短暂受影响。
EOF
}

cmd_list() {
  [ -s "$DEVICES_LIST" ] || die "设备名单不存在：$DEVICES_LIST（先跑 20-secrets.sh）"
  printf '\n%-20s %-38s %s\n' "设备" "凭据" "平台"
  printf '%s\n' "--------------------------------------------------------------------------------"
  local n c p
  while read -r n c p; do
    printf '%-20s %-38s %s\n' "$n" "$c" "${p:-desktop}"
  done < <(device_rows)
  printf '\n共 %s 台。名单文件：%s\n\n' "$(device_rows | wc -l)" "$DEVICES_LIST"
}

# 改完名单后：重渲染服务端 + 重渲染某设备的客户端配置
apply_changes() {
  local dev="${1:-}"
  log "重渲染服务端配置"
  local log_; log_="$(mktemp)"
  if ! bash "$SELF_DIR/30-render-server.sh" >"$log_" 2>&1; then
    cat "$log_" >&2; rm -f "$log_"
    die "服务端重渲染失败。名单已改，但配置未生效——先修好再重跑"
  fi
  grep -E '^\[' "$log_" || true
  rm -f "$log_"
  if [ -n "$dev" ]; then render_client "$dev"; fi
}

render_client() {
  local dev="$1" plat log_
  plat="$(device_get "$dev" | awk '{print $2}')"
  [ -n "$plat" ] || plat=desktop
  mkdir -p "$CLIENT_OUT"
  log_="$(mktemp)"
  if ! OUTDIR="$CLIENT_OUT" bash "$SELF_DIR/50-render-client.sh" "$CLIENT_ENV" --device "$dev" >"$log_" 2>&1; then
    cat "$log_" >&2; rm -f "$log_"
    die "客户端配置渲染失败"
  fi
  rm -f "$log_"
  log "客户端配置：$CLIENT_OUT/sing-box-client-$dev-$plat.json"
  log "分发：scp $CLIENT_OUT/sing-box-client-$dev-$plat.json <设备>:/root/  （只发这一台的那份）"
}

[ $# -ge 1 ] || { usage; exit 1; }
CMD="$1"; shift

case "$CMD" in
  list|-l)
    cmd_list
    ;;

  add)
    [ $# -ge 1 ] || { usage; die "add 需要设备名"; }
    NAME="$1"; PLATFORM="${2:-desktop}"
    valid_device_name "$NAME" || die "设备名不合法：$NAME（只允许字母数字 . _ -）"
    case " $VALID_PLATFORMS " in *" $PLATFORM "*) ;; *) die "平台只能是：$VALID_PLATFORMS" ;; esac
    device_exists "$NAME" && die "设备 $NAME 已存在（rotate 换凭据 / revoke 删除）"
    [ -s "$DEVICES_LIST" ] || die "设备名单不存在：$DEVICES_LIST（先跑 20-secrets.sh）"
    CRED="$("$SB_BIN" generate uuid)"
    printf '%s %s %s\n' "$NAME" "$CRED" "$PLATFORM" >>"$DEVICES_LIST"
    chmod 600 "$DEVICES_LIST"
    log "已新增设备 $NAME（$PLATFORM）"
    apply_changes "$NAME"
    ;;

  rotate)
    [ $# -ge 1 ] || { usage; die "rotate 需要设备名"; }
    NAME="$1"
    device_exists "$NAME" || die "设备名单里没有 $NAME"
    CRED="$("$SB_BIN" generate uuid)"
    # 原地替换那一行；保留平台列
    PLATFORM="$(device_get "$NAME" | awk '{print $2}')"
    awk -v n="$NAME" -v c="$CRED" -v p="${PLATFORM:-desktop}" '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
      $1 == n { print n, c, p; next }
      { print }
    ' "$DEVICES_LIST" >"$DEVICES_LIST.tmp"
    mv "$DEVICES_LIST.tmp" "$DEVICES_LIST"
    chmod 600 "$DEVICES_LIST"
    log "已轮换设备 $NAME 的凭据（旧配置已失效）"
    apply_changes "$NAME"
    ;;

  revoke)
    [ $# -ge 1 ] || { usage; die "revoke 需要设备名"; }
    NAME="$1"
    device_exists "$NAME" || die "设备名单里没有 $NAME"
    [ -n "$(device_rows | grep -v "^$NAME[[:space:]]")" ] || die "名单里只剩这一台，不能删空（先 add 再删）"
    awk -v n="$NAME" '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
      $1 == n { next }
      { print }
    ' "$DEVICES_LIST" >"$DEVICES_LIST.tmp"
    mv "$DEVICES_LIST.tmp" "$DEVICES_LIST"
    chmod 600 "$DEVICES_LIST"
    log "已吊销设备 $NAME"
    rm -f "$CLIENT_OUT/sing-box-client-$NAME-"*.json 2>/dev/null || true
    apply_changes ""
    log "记得把那台机器上的配置删掉，以及从任何保存了凭据的地方清除"
    ;;

  render)
    [ $# -ge 1 ] || { usage; die "render 需要设备名"; }
    NAME="$1"
    device_exists "$NAME" || die "设备名单里没有 $NAME"
    render_client "$NAME"
    ;;

  -h|--help|help) usage ;;

  *) usage; die "未知命令：$CMD" ;;
esac