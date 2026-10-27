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
# 真相源是 ${DEVICES_LIST}（默认 /etc/sing-box/devices.list），建议纳入 git。
# 一台设备一个凭据，同时当 VLESS uuid 与 Hysteria2 password——吊销因此是原子的。
#
# 在【服务器】上跑：它就地改名单、重渲染服务端、重渲染该设备的客户端 JSON。
# 本地生成客户端配置请用 bin/deploy/client/render.sh（默认输出到 ./data）。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "${SELF_DIR}/lib.sh"
need_root

CLIENT_OUT="${CLIENT_OUT:-${DEPLOY_DIR}/clients}"
VALID_PLATFORMS="desktop android ios"

# 子脚本（bin/deploy/client/render.sh / bin/deploy/one/server.sh）靠环境变量找这些文件，必须导出
export DEPLOY_DIR ENVFILE CLIENT_ENV DEVICES_LIST

usage() {
  cat <<EOF
用法：sudo bash device.sh <命令> [参数]

  list                      列出设备名单
  add <名字> [平台]         新增一台并生成凭据（平台默认 desktop）
  rotate <名字>             换掉凭据，旧配置立刻失效
  revoke <名字>             删除设备，立刻失效
  render <名字>             只重新渲染该设备的客户端配置，不动服务端
  export <名字>             渲染并打包成 tar.gz，附 SHA256SUMS 与 URI.txt
  share <名字>              只打印这一台的分享链接（等价于 bin/deploy/share.sh）

环境变量：
  DEVICES_LIST  设备名单路径（默认 /etc/sing-box/devices.list）
  CLIENT_OUT    客户端配置输出目录（默认 ${DEPLOY_DIR}/clients）
  CLIENT_ENV    客户端环境文件（默认 /etc/sing-box/client.env）
  SSH_LOGIN_USER  分发提示里登录服务器的用户（默认 root）

注意：add / rotate / revoke 都会重启 sing-box。当前有活跃会话时，
连接不会断（规则已建立），但新连接会短暂受影响。
EOF
}

cmd_list() {
  [[ -s "${DEVICES_LIST}" ]] || die "设备名单不存在：${DEVICES_LIST}（先跑 bin/deploy/one/secrets.sh）"
  printf '\n%-20s %-38s %s\n' "设备" "凭据" "平台"
  printf '%s\n' "--------------------------------------------------------------------------------"
  local n c p
  while read -r n c p; do
    printf '%-20s %-38s %s\n' "${n}" "${c}" "${p:-desktop}"
  done < <(device_rows)
  printf '\n共 %s 台。名单文件：%s\n\n' "$(device_rows | wc -l)" "${DEVICES_LIST}"
}

# 改完名单后：重渲染服务端 + 重渲染某设备的客户端配置
apply_changes() {
  local dev="${1:-}"
  log "重渲染服务端配置"
  local log_
  log_="$(mktemp)"
  if ! bash "${SELF_DIR}/one/server.sh" >"${log_}" 2>&1; then
    cat "${log_}" >&2
    rm -f "${log_}"
    die "名单已改但服务端重渲染失败，配置未生效"
  fi
  grep -E '^\[' "${log_}" || true
  rm -f "${log_}"
  if [[ -n "${dev}" ]]; then render_client "${dev}"; fi
}

# 分发命令的服务端参数：端口与 user@host 取自 deploy.env，缺值时保留占位符。
# 写成两个变量而不是一个拼好的前缀：一条 scp 里有两个远端源，-P 只能出现一次。
# 客户端默认以 root 登录，用 SSH_LOGIN_USER 覆盖。
DIST_PORT=22
DIST_USER_AT_HOST="root@<服务器IP>"
dist_conf() {
  load_env_optional "${ENVFILE}" || true
  DIST_PORT="${SSH_PORT:-22}"
  DIST_USER_AT_HOST="${SSH_LOGIN_USER:-root}@${SERVER_IP:-<服务器IP>}"
}

render_client() {
  local dev="$1" plat log_
  plat="$(device_get "${dev}" | awk '{print $2}')"
  [[ -n "${plat}" ]] || plat=desktop
  mkdir -p "${CLIENT_OUT}"
  log_="$(mktemp)"
  # 这份 JSON 要在别的机器上跑，缓存路径不能带本机 HOME：写成相对路径，
  # 由客户端自己解析到运行目录。要固定位置就在渲染前给 SING_BOX_CACHE_FILE。
  export SING_BOX_CACHE_FILE="${SING_BOX_CACHE_FILE:-cache.db}"
  if ! OUTDIR="${CLIENT_OUT}" bash "${SELF_DIR}/client/render.sh" "${CLIENT_ENV}" --device "${dev}" >"${log_}" 2>&1; then
    cat "${log_}" >&2
    rm -f "${log_}"
    die "客户端配置渲染失败"
  fi
  rm -f "${log_}"
  log "客户端配置：${CLIENT_OUT}/sing-box-client-${dev}-${plat}.json"
  # 文件在服务器上，实际传输由客户端发起：源在服务器、目标在本地
  dist_conf
  log "分发（在客户端执行）：scp -P ${DIST_PORT} ${DIST_USER_AT_HOST}:${CLIENT_OUT}/sing-box-client-${dev}-${plat}.json ."
}

if [[ $# -eq 0 ]]; then
  if ui_has_tty; then
    actions=(
      "list|列出设备名单"
      "add|新增设备并生成凭据"
      "rotate|轮换凭据，旧配置立刻失效"
      "revoke|删除设备"
      "render|只重新渲染该设备的客户端配置"
      "export|渲染并打包，附校验和"
    )
    ui_menu "设备凭据" "${actions[@]}"
    case "${UI_CHOICE}" in
      list) set -- list ;;
      *)
        ui_ask "设备名"
        set -- "${UI_CHOICE}" "${UI_ANSWER}"
        ;;
    esac
  else
    usage
    usage_error "非交互环境请给出命令：device.sh <list|add|rotate|revoke|render>"
  fi
fi
CMD="$1"
shift

case "${CMD}" in
  list | -l)
    cmd_list
    ;;

  add)
    [[ $# -ge 1 ]] || {
      usage
      die "add 需要设备名"
    }
    NAME="$1"
    PLATFORM="${2:-desktop}"
    valid_device_name "${NAME}" || die "设备名不合法：${NAME}（只允许字母数字 . _ -）"
    case " ${VALID_PLATFORMS} " in *" ${PLATFORM} "*) ;; *) die "平台只能是：${VALID_PLATFORMS}" ;; esac
    device_exists "${NAME}" && die "设备 ${NAME} 已存在（rotate 换凭据 / revoke 删除）"
    [[ -s "${DEVICES_LIST}" ]] || die "设备名单不存在：${DEVICES_LIST}（先跑 bin/deploy/one/secrets.sh）"
    CRED="$("${SB_BIN}" generate uuid)"
    printf '%s %s %s\n' "${NAME}" "${CRED}" "${PLATFORM}" >>"${DEVICES_LIST}"
    chmod 600 "${DEVICES_LIST}"
    log "已新增设备 ${NAME}（${PLATFORM}）"
    apply_changes "${NAME}"
    ;;

  rotate)
    [[ $# -ge 1 ]] || {
      usage
      die "rotate 需要设备名"
    }
    NAME="$1"
    device_exists "${NAME}" || die "设备名单里没有 ${NAME}"
    CRED="$("${SB_BIN}" generate uuid)"
    # 原地替换那一行；保留平台列
    PLATFORM="$(device_get "${NAME}" | awk '{print $2}')"
    awk -v n="${NAME}" -v c="${CRED}" -v p="${PLATFORM:-desktop}" '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
      $1 == n { print n, c, p; next }
      { print }
    ' "${DEVICES_LIST}" >"${DEVICES_LIST}.tmp"
    mv "${DEVICES_LIST}.tmp" "${DEVICES_LIST}"
    chmod 600 "${DEVICES_LIST}"
    log "已轮换设备 ${NAME} 的凭据（旧配置已失效）"
    apply_changes "${NAME}"
    ;;

  revoke)
    [[ $# -ge 1 ]] || {
      usage
      die "revoke 需要设备名"
    }
    NAME="$1"
    device_exists "${NAME}" || die "设备名单里没有 ${NAME}"
    device_rows | grep -qv "^${NAME}[[:space:]]" || die "名单里只剩这一台，先 add 再删"
    awk -v n="${NAME}" '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
      $1 == n { next }
      { print }
    ' "${DEVICES_LIST}" >"${DEVICES_LIST}.tmp"
    mv "${DEVICES_LIST}.tmp" "${DEVICES_LIST}"
    chmod 600 "${DEVICES_LIST}"
    log "已吊销设备 ${NAME}"
    rm -f "${CLIENT_OUT}/sing-box-client-${NAME}-"*.json 2>/dev/null || true
    apply_changes ""
    log "记得把那台机器上的配置删掉，以及从任何保存了凭据的地方清除"
    ;;

  share)
    [[ $# -ge 1 ]] || {
      usage
      die "share 需要设备名"
    }
    device_exists "$1" || die "设备名单里没有 $1"
    uri_list "$1"
    ;;
  export)
    [[ $# -ge 1 ]] || {
      usage
      die "export 需要设备名"
    }
    NAME="$1"
    device_exists "${NAME}" || die "设备名单里没有 ${NAME}"
    render_client "${NAME}"
    plat="$(device_get "${NAME}" | awk '{print $2}')"
    [[ -n "${plat}" ]] || plat=desktop
    src="${CLIENT_OUT}/sing-box-client-${NAME}-${plat}.json"
    [[ -f "${src}" ]] || die "渲染产物不存在：${src}"
    dist="${CLIENT_OUT}/dist"
    install -d -m 700 "${dist}"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    pkg="${dist}/${NAME}-${stamp}.tar.gz"
    # 只把这一台的配置放进包里：包里出现其他设备的凭据就是事故
    stage=""
    mktemp_dir stage
    cp "${src}" "${stage}/"
    # 同一份凭据的分享链接：供只认 URI 的客户端导入
    uri_list "${NAME}" >"${stage}/URI.txt"
    (cd "${stage}" && sha256sum ./*.json ./URI.txt >SHA256SUMS)
    tar -czf "${pkg}" -C "${stage}" .
    (cd "${dist}" && sha256sum "$(basename "${pkg}")" >"$(basename "${pkg}").sha256")
    chmod 600 "${pkg}" "${pkg}.sha256"
    log "已导出：${pkg}（$(du -h "${pkg}" | cut -f1)）"
    log "包内校验和：$(cut -d' ' -f1 "${pkg}.sha256")"
    dist_conf
    log "分发（在客户端执行；源在服务器，目标在本地当前目录）："
    log "    scp -P ${DIST_PORT} ${DIST_USER_AT_HOST}:${pkg} ${DIST_USER_AT_HOST}:${pkg}.sha256 ."
    log "校验并解包：sha256sum -c $(basename "${pkg}").sha256 && tar -xzf $(basename "${pkg}")    # macOS 用 shasum -a 256 -c"
    ;;
  render)
    [[ $# -ge 1 ]] || {
      usage
      die "render 需要设备名"
    }
    NAME="$1"
    device_exists "${NAME}" || die "设备名单里没有 ${NAME}"
    render_client "${NAME}"
    ;;

  -h | --help | help) usage ;;

  *)
    usage
    die "未知命令：${CMD}"
    ;;
esac
