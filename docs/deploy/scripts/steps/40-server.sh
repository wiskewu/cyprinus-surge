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
  T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN

  # users 数组按设备名单渲染：一份设备名单 = 一组凭据，删一行就吊销那台
  local rows; rows="$(device_rows)"
  [[ -n "${rows}" ]] || die "设备名单为空：${DEVICES_LIST}"

  render_vars "${TPL_DIR}/in-reality.json.tmpl" "${T}/in1.json"
  render_users "${rows}" uuid "${T}/u1.json"
  inject_block "${T}/in1.json" "__USERS__" "${T}/u1.json"
  cp "${T}/in1.json" "${T}/inbounds.json"
  if [[ "${ENABLE_HY2:-0}" == "1" ]]; then
    for f in cert.pem key.pem; do
      [[ -s "${DEPLOY_DIR}/${f}" ]] || die "缺少 ${DEPLOY_DIR}/${f}：先跑 Hysteria2 步骤，或把 ENABLE_HY2 改成 0"
    done
    render_vars "${TPL_DIR}/in-hy2.json.tmpl" "${T}/in2.json"
    render_users "${rows}" password "${T}/u2.json"
    inject_block "${T}/in2.json" "__USERS__" "${T}/u2.json"
    join_json "${T}/in1.json" "${T}/in2.json" >"${T}/inbounds.json"
    log "双入口：REALITY:${VLESS_PORT} + Hysteria2:${HY2_PORT}/udp（$(printf '%s\n' "${rows}" | wc -l) 台设备）"
  else
    log "单入口：REALITY:${VLESS_PORT}（$(printf '%s\n' "${rows}" | wc -l) 台设备）"
  fi

  render_vars "${TPL_DIR}/server.json.tmpl" "${T}/server.json"
  inject_block "${T}/server.json" "__INBOUNDS__" "${T}/inbounds.json"
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
  install -m 600 "${T}/server.json" "${DEPLOY_DIR}/config.json"
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 30 --no-pager; die "sing-box 没起来"; }
  log "服务已启动"
}

server_uninstall() {
  systemctl stop sing-box >/dev/null 2>&1 || true
  rm -f "${DEPLOY_DIR}/config.json"
  log "已停止服务并删除 config.json（密钥与证书保留）"
}
