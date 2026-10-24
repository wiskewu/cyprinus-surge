#!/usr/bin/env bash
# 80-monitor.sh —— 服务端观测：只读 clash_api + 定时探针。
#   探针记四件事：服务与端口、服务器出口 IP、AI 站点可达性、到 1.1.1.1 的丢包与延迟。
#   结果按 CSV 追加到 /var/lib/sing-box-monitor/probe.log，定时器每 5 分钟跑一次。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "${SELF_DIR}/lib.sh"

STATE_DIR="${STATE_DIR:-/var/lib/sing-box-monitor}"
PROBE_LOG="${STATE_DIR}/probe.log"
PROBE_KEEP="${PROBE_KEEP:-5000}"
SERVICE_UNIT="/etc/systemd/system/sing-box-probe.service"
TIMER_UNIT="/etc/systemd/system/sing-box-probe.timer"
CLASH_API_LISTEN="${CLASH_API_LISTEN:-127.0.0.1:9090}"

MODE=setup

usage() {
  cat <<'EOF'
用法：sudo bash 80-monitor.sh [选项]

  （不带选项）        安装：打开 clash_api（重新渲染并重启 sing-box）+ 装 5 分钟探针定时器
  --clash-api on|off  只切换 clash_api；on 会重渲染服务端配置
  --probe             立刻跑一次探针，结果追加到 probe.log
  --status            看最近 20 条探针与 clash_api 概览
  --uninstall         停并删定时器，关掉 clash_api
  -h, --help          显示帮助

clash_api 只绑 127.0.0.1。远程看面板走 SSH 隧道：
  ssh -N -L 9090:127.0.0.1:9090 <服务器>
然后在浏览器打开 http://127.0.0.1:9090/ui
EOF
}

CLASH_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clash-api)
      shift
      CLASH_ARG="${1:?--clash-api 需要 on|off}"
      MODE=clash
      ;;
    --clash-api=*)
      CLASH_ARG="${1#*=}"
      MODE=clash
      ;;
    --probe) MODE=probe ;;
    --status) MODE=status ;;
    --uninstall) MODE=uninstall ;;
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

# deploy.env 可有可无：有就读端口与开关。注意 die 是 exit，不能靠 || true 兜住
[[ -f "${ENVFILE}" ]] && load_env "${ENVFILE}"
VLESS_PORT="${VLESS_PORT:-443}"
HY2_PORT="${HY2_PORT:-8443}"
ENABLE_HY2="${ENABLE_HY2:-0}"

env_set() { # $1=键 $2=值，写回 deploy.env（缺行就追加）
  [[ -f "${ENVFILE}" ]] || die "缺少 ${ENVFILE}，先跑 20-secrets.sh"
  if grep -q "^$1=" "${ENVFILE}"; then
    sed -i "s|^$1=.*|$1=$2|" "${ENVFILE}"
  else
    printf '%s=%s\n' "$1" "$2" >>"${ENVFILE}"
  fi
}

port_listening() { # $1=tcp|udp $2=端口
  if [[ "$1" == tcp ]]; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$2\$"
  else
    ss -ulnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$2\$"
  fi
}

# ---------------------------------------------------------------- 探针
rtt_of() { # 从 ping 输出里取 "丢包率 平均延迟"
  local out loss avg
  out="$(ping -c 3 -W 2 1.1.1.1 2>/dev/null || true)"
  loss="$(printf '%s' "${out}" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+' || true)"
  avg="$(printf '%s' "${out}" | awk -F'/' '/rtt|round-trip/ {print $5}' || true)"
  printf '%s %s\n' "${loss:--}" "${avg:--}"
}

ai_of() { # 输出 "状态码 loc"
  local out code loc
  out="$(curl -sS -m 10 -w '\n%{http_code}' https://chatgpt.com/cdn-cgi/trace 2>/dev/null || true)"
  code="$(printf '%s' "${out}" | tail -n1)"
  loc="$(printf '%s' "${out}" | awk -F= '$1=="loc"{print $2}')"
  printf '%s %s\n' "${code:--}" "${loc:--}"
}

probe_once() {
  local ts svc tcp udp ip ai_code ai_loc loss avg
  ts="$(date -u +%FT%TZ)"
  svc="$(systemctl is-active sing-box 2>/dev/null || printf 'down')"
  port_listening tcp "${VLESS_PORT}" && tcp=up || tcp=down
  if [[ "${ENABLE_HY2}" == "1" ]]; then
    port_listening udp "${HY2_PORT}" && udp=up || udp=down
  else
    udp="n/a"
  fi
  ip="$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null || printf '-')"
  read -r ai_code ai_loc <<<"$(ai_of)"
  read -r loss avg <<<"$(rtt_of)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${ts}" "${svc}" "${tcp}" "${udp}" "${ip}" "${ai_code}" "${ai_loc}" "${loss}" "${avg}"
}

log_is_writable() { mkdir -p "${STATE_DIR}" && chmod 750 "${STATE_DIR}"; }

trim_log() {
  [[ -f "${PROBE_LOG}" ]] || return 0
  local n
  n="$(wc -l <"${PROBE_LOG}" | tr -d ' ')"
  [[ "${n}" -gt "${PROBE_KEEP}" ]] || return 0
  tail -n "${PROBE_KEEP}" "${PROBE_LOG}" >"${PROBE_LOG}.tmp" && mv "${PROBE_LOG}.tmp" "${PROBE_LOG}"
}

run_probe() {
  need_root
  log_is_writable
  [[ -f "${PROBE_LOG}" ]] || printf 'ts,service,tcp,udp,egress,ai_code,ai_loc,loss_pct,rtt_avg_ms\n' >"${PROBE_LOG}"
  probe_once >>"${PROBE_LOG}"
  trim_log
}

# ---------------------------------------------------------------- 状态
show_status() {
  need_root
  printf '== 服务 ==\n'
  printf '%s\t%s\n' 'sing-box' "$(systemctl is-active sing-box 2>/dev/null || printf '未知')"
  printf '%s\t%s\n' 'VLESS 端口' "$(port_listening tcp "${VLESS_PORT}" && printf '%s/tcp 在监听' "${VLESS_PORT}" || printf '%s/tcp 未监听' "${VLESS_PORT}")"
  if [[ "${ENABLE_HY2}" == "1" ]]; then
    printf '%s\t%s\n' 'Hysteria2' "$(port_listening udp "${HY2_PORT}" && printf '%s/udp 在监听' "${HY2_PORT}" || printf '%s/udp 未监听' "${HY2_PORT}")"
  fi
  printf '%s\t%s\n' '探针定时器' "$(systemctl is-active sing-box-probe.timer 2>/dev/null || printf '未安装')"

  printf '\n== 最近探针 ==\n'
  if [[ -f "${PROBE_LOG}" ]]; then
    head -n1 "${PROBE_LOG}" | tr ',' '\t' | awk '{printf "%-20s %-8s %-5s %-5s %-16s %-8s %-4s %-8s %s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9}'
    tail -n 20 "${PROBE_LOG}" | tail -n +2 | tr ',' '\t' | awk '{printf "%-20s %-8s %-5s %-5s %-16s %-8s %-4s %-8s %s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9}'
  else
    printf '还没有记录，跑一次：sudo bash %s --probe\n' "$0"
  fi

  printf '\n== clash_api ==\n'
  if ! curl -fsS -m 3 "http://${CLASH_API_LISTEN}/version" >/dev/null 2>&1; then
    printf '未开启（sudo bash %s --clash-api on）\n' "$0"
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    curl -fsS -m 3 "http://${CLASH_API_LISTEN}/connections" \
      | jq -r '"连接数 \(.connections | length)  下载 \(.downloadTotal / 1048576 | floor) MiB  上传 \(.uploadTotal / 1048576 | floor) MiB",
             (.connections | group_by(.chains | last) | map("  \(.[0].chains | last): \(length) 条") | .[])' 2>/dev/null \
      || printf '解析失败，直接看原始输出：curl -s http://%s/connections\n' "${CLASH_API_LISTEN}"
  else
    printf '未装 jq，原始输出：curl -s http://%s/connections\n' "${CLASH_API_LISTEN}"
  fi
}

# ---------------------------------------------------------------- clash_api
set_clash_api() {
  local want="$1"
  need_root
  case "${want}" in on | off) ;; *) die "--clash-api 只接受 on / off" ;; esac
  if [[ "${want}" == on ]]; then
    env_set ENABLE_CLASH_API 1
    env_set CLASH_API_LISTEN "${CLASH_API_LISTEN}"
    log "重新渲染服务端配置并重启 sing-box"
    bash "${SELF_DIR}/30-render-server.sh"
    curl -fsS -m 3 "http://${CLASH_API_LISTEN}/version" >/dev/null 2>&1 \
      || die "clash_api 没起来：检查 config.json 的 experimental.clash_api，以及 ${ENVFILE} 里的 ENABLE_CLASH_API"
    log "clash_api 已开启：${CLASH_API_LISTEN}（SSH 隧道：ssh -N -L 9090:127.0.0.1:9090 <服务器>）"
  else
    env_set ENABLE_CLASH_API 0
    log "关闭 clash_api 并重启 sing-box"
    bash "${SELF_DIR}/30-render-server.sh"
  fi
}

# ---------------------------------------------------------------- 定时器
install_timer() {
  need_root
  cat >"${SERVICE_UNIT}" <<EOF
[Unit]
Description=sing-box probe (port / egress / AI / rtt)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${SELF_DIR}/80-monitor.sh --probe
Nice=10
EOF
  cat >"${TIMER_UNIT}" <<'EOF'
[Unit]
Description=sing-box probe timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now sing-box-probe.timer >/dev/null 2>&1
  log "探针定时器已启用：每 5 分钟一次，记录在 ${PROBE_LOG}"
}

remove_timer() {
  systemctl disable --now sing-box-probe.timer >/dev/null 2>&1 || true
  rm -f "${SERVICE_UNIT}" "${TIMER_UNIT}"
  systemctl daemon-reload
  log "探针定时器已移除（记录保留）"
}

# ---------------------------------------------------------------- 主流程
case "${MODE}" in
  probe)
    run_probe
    exit 0
    ;;
  status)
    show_status
    exit 0
    ;;
  clash)
    set_clash_api "${CLASH_ARG}"
    exit 0
    ;;
  uninstall)
    need_root
    remove_timer
    set_clash_api off || true
    log "已卸载观测：定时器与 clash_api 都关了"
    exit 0
    ;;
esac

need_root
log "1/2 打开 clash_api"
set_clash_api on
log "2/2 安装探针定时器"
install_timer
run_probe
show_status
