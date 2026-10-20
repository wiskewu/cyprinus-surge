# 步骤 40：渲染服务端配置并启动
server_TITLE="渲染服务端配置并启动（双入口）"
server_OPTIONAL=0

server_check() {
  [ -s "$DEPLOY_DIR/config.json" ] || return 1
  systemctl is-active --quiet sing-box 2>/dev/null || return 1
  return 0
}

server_run() {
  local T
  load_env "$ENVFILE"
  export CERT_DIR="${CERT_DIR:-$DEPLOY_DIR}"
  [ -x "$SB_BIN" ] || die "sing-box 未安装"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN

  render_vars "$TPL_DIR/in-reality.json.tmpl" "$T/in1.json"
  cp "$T/in1.json" "$T/inbounds.json"
  if [ "${ENABLE_HY2:-0}" = "1" ]; then
    for f in cert.pem key.pem; do
      [ -s "$DEPLOY_DIR/$f" ] || die "缺少 $DEPLOY_DIR/$f：先跑 Hysteria2 步骤，或把 ENABLE_HY2 改成 0"
    done
    render_vars "$TPL_DIR/in-hy2.json.tmpl" "$T/in2.json"
    join_json "$T/in1.json" "$T/in2.json" >"$T/inbounds.json"
    log "双入口：REALITY:${VLESS_PORT} + Hysteria2:${HY2_PORT}/udp"
  else
    log "单入口：REALITY:${VLESS_PORT}"
  fi

  render_vars "$TPL_DIR/server.json.tmpl" "$T/server.json"
  inject_block "$T/server.json" "__INBOUNDS__" "$T/inbounds.json"
  json_valid "$T/server.json"
  sb_check "$T/server.json"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    local out="${OUT:-config.preview.json}"
    case "$out" in /*) ;; *) out="./$out" ;; esac
    cp "$T/server.json" "$out"
    log "DRY_RUN：已生成 $out"
    return 0
  fi
  install -m 600 "$T/server.json" "$DEPLOY_DIR/config.json"
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 30 --no-pager; die "sing-box 没起来"; }
  log "服务已启动"
}

server_uninstall() {
  systemctl stop sing-box >/dev/null 2>&1 || true
  rm -f "$DEPLOY_DIR/config.json"
  log "已停止服务并删除 config.json（密钥与证书保留）"
}
