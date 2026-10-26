# shellcheck shell=bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
# 步骤 40：渲染服务端配置并启动
server_TITLE="渲染服务端配置并启动（双入口）"
server_OPTIONAL=0

server_check() {
  [[ -s "${DEPLOY_DIR}/config.json" ]] || return 1
  systemctl is-active --quiet sing-box 2>/dev/null || return 1
  return 0
}

# 把设备名单渲染成 sing-box 的 users 数组内容（逗号分隔，不含外层方括号）。
# 模板里写 "users": [[ __USERS__ ]]，方括号由模板负责。
# $1=名单内容 $2=凭据字段名(uuid|password) $3=输出文件
render_users() {
  local rows="$1" field="$2" out="$3" n c p first=1
  : >"${out}"
  while read -r n c p; do
    [[ -n "${first}" ]] || printf ',\n' >>"${out}"
    if [[ "${field}" == uuid ]]; then
      printf '        { "name": "%s", "uuid": "%s", "flow": "xtls-rprx-vision" }' "${n}" "${c}" >>"${out}"
    else
      printf '        { "name": "%s", "password": "%s" }' "${n}" "${c}" >>"${out}"
    fi
    first=""
  done <<<"${rows}"
  [[ -n "${first}" ]] && die "设备名单解析不出条目：${DEVICES_LIST}"
  return 0
}

server_run() {
  local T
  load_env "${ENVFILE}"
  export CERT_DIR="${CERT_DIR:-${DEPLOY_DIR}}"
  [[ -x "${SB_BIN}" ]] || die "sing-box 未安装"
  mktemp_dir T

  # users 数组按设备名单渲染：一份设备名单 = 一组凭据，删一行就吊销那台
  local rows
  rows="$(device_rows)"
  [[ -n "${rows}" ]] || die "设备名单为空：${DEVICES_LIST}"

  render_vars "${TPL_DIR}/in-reality.json.tmpl" "${T}/in1.json"
  render_users "${rows}" uuid "${T}/u1.json"
  inject_block "${T}/in1.json" "__USERS__" "${T}/u1.json"
  cp "${T}/in1.json" "${T}/inbounds.json"
  if [[ "${ENABLE_HY2:-0}" == "1" ]]; then
    for f in cert.pem key.pem; do
      [[ -s "${DEPLOY_DIR}/${f}" ]] || die "缺少 ${DEPLOY_DIR}/${f}：先跑 bash deploy.sh --only hy2 签发证书，或把 deploy.env 里的 ENABLE_HY2 改成 0 后重跑 server"
    done
    render_vars "${TPL_DIR}/in-hy2.json.tmpl" "${T}/in2.json"
    render_users "${rows}" password "${T}/u2.json"
    inject_block "${T}/in2.json" "__USERS__" "${T}/u2.json"
    join_json "${T}/in1.json" "${T}/in2.json" >"${T}/inbounds.json"
    log "双入口：REALITY:${VLESS_PORT} + Hysteria2:${HY2_PORT}/udp（$(printf '%s\n' "${rows}" | wc -l) 台设备）"
  else
    log "单入口：REALITY:${VLESS_PORT}（$(printf '%s\n' "${rows}" | wc -l) 台设备）"
  fi

  # 规则集缓存：没有 cache_file 时每次重启都要重新下载 .srs，弱网下冷启动直接失败
  export CACHE_FILE="${SING_BOX_CACHE_FILE:-/var/lib/sing-box/cache.db}"
  render_vars "${TPL_DIR}/server.json.tmpl" "${T}/server.json"
  inject_block "${T}/server.json" "__INBOUNDS__" "${T}/inbounds.json"
  # clash_api 只读面板：绑回环，配合 SSH 隧道用。关掉时只留 cache_file。
  # cache_file 必须放在 experimental 里：1.13 起顶层写法被移除，写成顶层会直接
  # 报 unknown field "cache_file" 并拒绝启动。
  local exp_frag="${T}/experimental.json" exp_parts=()
  exp_parts+=("    \"cache_file\": { \"enabled\": true, \"path\": \"${CACHE_FILE}\" }")
  if [[ "${ENABLE_CLASH_API:-0}" == "1" ]]; then
    # 面板文件放在运行目录下，不进 /etc 备份；没有就在只读接口模式下工作
    if [[ -d /var/lib/sing-box/ui ]]; then
      exp_parts+=("    \"clash_api\": { \"external_controller\": \"${CLASH_API_LISTEN:-127.0.0.1:9090}\", \"external_ui\": \"/var/lib/sing-box/ui\" }")
    else
      exp_parts+=("    \"clash_api\": { \"external_controller\": \"${CLASH_API_LISTEN:-127.0.0.1:9090}\" }")
    fi
  fi
  {
    local i
    for i in "${!exp_parts[@]}"; do
      printf '%s' "${exp_parts[i]}"
      [[ "${i}" -lt $((${#exp_parts[@]} - 1)) ]] && printf ','
      printf '\n'
    done
  } >"${exp_frag}"
  inject_block "${T}/server.json" "__EXPERIMENTAL__" "${exp_frag}"
  json_valid "${T}/server.json"
  sb_check "${T}/server.json"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    # 预览也走 data/：脚本目录是入库的，往里写会把服务端配置（含 REALITY 私钥）带进版本控制
    local out="${OUT:-data/config.preview.json}"
    mkdir -p "$(dirname "${out}")"
    cp "${T}/server.json" "${out}"
    log "DRY_RUN：已生成 ${out}"
    return 0
  fi
  install_service_file "${T}/server.json" "${DEPLOY_DIR}/config.json"
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || {
    # 只贴本次重启前后的日志：默认 -n 30 会把几小时前的握手噪音一起打出来，
    # 真因（比如 chdir permission denied）反而被冲掉
    journalctl -u sing-box -n 30 --no-pager --since "-2 min" || true
    die "sing-box 没起来"
  }
  log "服务已启动"
}

server_uninstall() {
  systemctl stop sing-box >/dev/null 2>&1 || true
  rm -f "${DEPLOY_DIR}/config.json"
  log "已停止服务并删除 config.json（密钥与证书保留）"
}
