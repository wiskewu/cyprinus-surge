#!/usr/bin/env bash
# bin/deploy/ops/monitor.sh —— 服务端观测：只读 clash_api + 定时探针。
#   探针记四件事：服务与端口、服务器出口 IP、AI 站点可达性、到 1.1.1.1 的丢包与延迟。
#   结果按 CSV 追加到 /var/lib/sing-box-monitor/probe.log，定时器每 5 分钟跑一次。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"

STATE_DIR="${STATE_DIR:-/var/lib/sing-box-monitor}"
PROBE_LOG="${STATE_DIR}/probe.log"
PROBE_KEEP="${PROBE_KEEP:-5000}"
SERVICE_UNIT="/etc/systemd/system/sing-box-probe.service"
TIMER_UNIT="/etc/systemd/system/sing-box-probe.timer"
CLASH_API_LISTEN="${CLASH_API_LISTEN:-127.0.0.1:9090}"

MODE=setup

usage() {
  cat <<'EOF'
用法：sudo bash bin/deploy/ops/monitor.sh [选项]

  （不带选项）        安装：打开 clash_api（重新渲染并重启 sing-box）+ 装 5 分钟探针定时器
  --clash-api on|off  只切换 clash_api；on 会重渲染服务端配置
  --ui                下载面板（metacubexd）到运行目录，之后 /ui 可用
  --probe             走一次探针并评估告警
  --alert-check       只评估告警
  --alert-test        发一条测试告警
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
    --ui) MODE=ui ;;
    --probe) MODE=probe ;;
    --alert-check) MODE=alertcheck ;;
    --alert-test) MODE=alerttest ;;
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
  [[ -f "${ENVFILE}" ]] || die "缺少 ${ENVFILE}，先跑 bin/deploy/one/secrets.sh"
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

# AI 出口判定：用 Cloudflare trace 拿状态码与机房。
# 403/429 表示「连上了但被拦」，可访问性仍然存在；拿不到任何响应才算不可达。
ai_of() { # 输出 "状态码 loc 可达性"
  local out code loc rc reach
  out="$(curl -sS -m 10 -w '\n%{http_code}' https://chatgpt.com/cdn-cgi/trace 2>/dev/null)"
  rc=$?
  code="$(printf '%s' "${out}" | tail -n1)"
  loc="$(printf '%s' "${out}" | awk -F= '$1=="loc"{print $2}')"
  case "${code}" in
    2?? | 4??) reach=ok ;;
    *) reach=fail ;;
  esac
  # curl 非零说明 TCP 或 TLS 就没走通
  [[ "${rc}" == 0 ]] || reach=fail
  printf '%s %s %s\n' "${code:--}" "${loc:--}" "${reach}"
}

probe_once() {
  local ts svc tcp udp ip ai_code ai_loc ai_reach loss avg
  ts="$(date -u +%FT%TZ)"
  svc="$(systemctl is-active sing-box 2>/dev/null || printf 'down')"
  port_listening tcp "${VLESS_PORT}" && tcp=up || tcp=down
  if [[ "${ENABLE_HY2}" == "1" ]]; then
    port_listening udp "${HY2_PORT}" && udp=up || udp=down
  else
    udp="n/a"
  fi
  ip="$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null || printf '-')"
  read -r ai_code ai_loc ai_reach <<<"$(ai_of)"
  read -r loss avg <<<"$(rtt_of)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${ts}" "${svc}" "${tcp}" "${udp}" "${ip}" "${ai_code}" "${ai_loc}" "${ai_reach}" "${loss}" "${avg}"
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
  [[ -f "${PROBE_LOG}" ]] || printf 'ts,service,tcp,udp,egress,ai_code,ai_loc,ai_reach,loss_pct,rtt_avg_ms\n' >"${PROBE_LOG}"
  probe_once >>"${PROBE_LOG}"
  trim_log
  alert_check || true
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
    bash "${SELF_DIR}/../one/server.sh"
    curl -fsS -m 3 "http://${CLASH_API_LISTEN}/version" >/dev/null 2>&1 \
      || die "clash_api 没起来：检查 config.json 的 experimental.clash_api，以及 ${ENVFILE} 里的 ENABLE_CLASH_API"
    log "clash_api 已开启：${CLASH_API_LISTEN}（SSH 隧道：ssh -N -L 9090:127.0.0.1:9090 <服务器>）"
  else
    env_set ENABLE_CLASH_API 0
    log "关闭 clash_api 并重启 sing-box"
    bash "${SELF_DIR}/../one/server.sh"
  fi
}

# ---------------------------------------------------------------- 面板
UI_DIR="/var/lib/sing-box/ui"

install_ui() {
  need_root
  local url="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
  command -v curl >/dev/null 2>&1 || die "缺少 curl"
  local pkg
  mktemp_dir pkg
  log "下载面板到 ${UI_DIR}"
  curl -fsSL -m 120 -o "${pkg}/ui.tgz" "${url}" \
    || die "下载失败；可手工把 metacubexd 的 dist 解到 ${UI_DIR}"
  install -d -m 750 "${UI_DIR}"
  tar xzf "${pkg}/ui.tgz" -C "${UI_DIR}" || die "解包失败"
  local owner
  owner="$(systemctl show -p User --value sing-box 2>/dev/null || true)"
  [[ -n "${owner}" ]] || owner=root
  chown -R "${owner}:$(id -gn "${owner}")" "${UI_DIR}"
  find "${UI_DIR}" -type d -exec chmod 750 {} +
  find "${UI_DIR}" -type f -exec chmod 640 {} +
  log "面板就位：$(du -sh "${UI_DIR}" | cut -f1)"
  printf '  打开方式：ssh -N -L 9090:127.0.0.1:9090 <服务器>，然后访问 http://127.0.0.1:9090/ui\n'
  # 让配置带上 external_ui
  bash "${SELF_DIR}/../one/server.sh"
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
ExecStart=/bin/bash ${SELF_DIR}/monitor.sh --probe
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

# ---------------------------------------------------------------- 告警
# 阈值都可用环境变量覆盖；推送支持 Telegram 与通用 webhook，都没有则只写日志。
ALERT_STATE="${STATE_DIR}/alert.state"

# 推送：多个通道可以同时配，任一成功即算送达。
# 大陆可直连的选项：企业微信/钉钉群机器人、Server酱、SMTP 邮件；
# Telegram 需要代理，服务器上通常不可达，保留但不建议作为主通道。
alert_send() { # $1=正文
  local text="$1" resp ok=0 title
  title="$(hostname) 告警"
  if [[ -n "${ALERT_WECOM_WEBHOOK:-}" ]]; then
    if resp="$(jq -n --arg t "${text}" '{msgtype: "text", text: {content: $t}}' \
      | curl -fsS -m 10 -H 'Content-Type: application/json' --data-binary @- "${ALERT_WECOM_WEBHOOK}" 2>&1)"; then
      ok=1
    else
      warn "企业微信推送失败：${resp}"
    fi
  fi
  if [[ -n "${ALERT_SERVERCHAN_KEY:-}" ]]; then
    if resp="$(curl -fsS -m 10 --data-urlencode "title=${title}" --data-urlencode "desp=${text}" \
      "https://sctapi.ftqq.com/${ALERT_SERVERCHAN_KEY}.send" 2>&1)"; then
      ok=1
    else
      warn "Server酱推送失败：${resp}"
    fi
  fi
  if [[ -n "${ALERT_SMTP_URL:-}" && -n "${ALERT_MAIL_TO:-}" ]]; then
    if resp="$(printf 'From: %s\nTo: %s\nSubject: %s\n\n%s\n' \
      "${ALERT_SMTP_USER:-alert@localhost}" "${ALERT_MAIL_TO}" "${title}" "${text}" \
      | curl -fsS -m 15 "${ALERT_SMTP_URL}" --mail-from "${ALERT_SMTP_USER:-alert@localhost}" \
        --mail-rcpt "${ALERT_MAIL_TO}" --user "${ALERT_SMTP_USER:-}:${ALERT_SMTP_PASS:-}" \
        --upload-file - 2>&1)"; then
      ok=1
    else
      warn "邮件推送失败：${resp}"
    fi
  fi
  if [[ -n "${ALERT_TG_TOKEN:-}" && -n "${ALERT_TG_CHAT:-}" ]]; then
    if resp="$(curl -fsS -m 10 "https://api.telegram.org/bot${ALERT_TG_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${ALERT_TG_CHAT}" --data-urlencode "text=${text}" 2>&1)"; then
      ok=1
    else
      warn "Telegram 推送失败：${resp}"
    fi
  fi
  if [[ -n "${ALERT_WEBHOOK:-}" ]]; then
    if resp="$(jq -n --arg t "${text}" '{text: $t}' \
      | curl -fsS -m 10 -H 'Content-Type: application/json' --data-binary @- "${ALERT_WEBHOOK}" 2>&1)"; then
      ok=1
    else
      warn "webhook 推送失败：${resp}"
    fi
  fi
  if [[ "${ok}" == 0 ]]; then
    warn "未配置任何推送通道，告警只写日志"
    return 1
  fi
  return 0
}

alert_check() {
  need_root
  log_is_writable
  local now cooldown problems="" last msg key last_ts cached
  now="$(date +%s)"
  cooldown="${ALERT_COOLDOWN_H:-6}"
  last="$(tail -n 1 "${PROBE_LOG}" 2>/dev/null || true)"

  # 1) 服务与端口：探针 CSV 里出现 down
  if printf '%s' "${last}" | grep -q ',down'; then
    problems="${problems}- 服务或端口异常：${last}%NL%"
  fi
  # 2) AI 出口不可达：403/429 属「连上了但被拦」，不算不可达
  if printf '%s' "${last}" | cut -d, -f8 | grep -qx 'fail'; then
    problems="${problems}- AI 出口不可达：code $(printf '%s' "${last}" | cut -d, -f6)%NL%"
  fi

  # 3) 月流量占比
  local used quota pct
  used="$(month_bytes)"
  quota="$(quota_bytes)"
  if [[ -n "${used}" && -n "${quota}" && "${quota}" != "0" ]]; then
    pct="$(awk -v u="${used}" -v q="${quota}" 'BEGIN { printf "%d", u * 100 / q }')"
    if [[ "${pct}" -ge "${ALERT_TRAFFIC_PCT:-80}" ]]; then
      problems="${problems}- 当月流量 ${pct}%：$(fmt_bytes "${used}")/$(fmt_bytes "${quota}")%NL%"
    fi
  fi

  # 4) 证书到期
  if [[ -r "${DEPLOY_DIR}/cert.pem" ]]; then
    local end days
    end="$(openssl x509 -enddate -noout -in "${DEPLOY_DIR}/cert.pem" 2>/dev/null | cut -d= -f2)"
    if [[ -n "${end}" ]]; then
      days="$((($(date -d "${end}" +%s) - now) / 86400))"
      if [[ "${days}" -le "${ALERT_CERT_DAYS:-14}" ]]; then
        problems="${problems}- 证书 ${days} 天后到期%NL%"
      fi
    fi
  fi

  if [[ -z "${problems}" ]]; then
    printf '无异常项\n'
    return 0
  fi

  msg="$(printf '%s' "${problems}" | sed 's/%NL%/\n/g')"
  key="$(printf '%s' "${msg}" | md5sum | cut -d' ' -f1)"
  if [[ -r "${ALERT_STATE}" ]]; then
    read -r last_ts cached <"${ALERT_STATE}" || true
    if [[ "${cached:-}" == "${key}" ]] && [[ $((now - ${last_ts:-0})) -lt $((cooldown * 3600)) ]]; then
      printf '冷却中，跳过推送\n'
      return 0
    fi
  fi
  printf '%s %s\n' "${now}" "${key}" >"${ALERT_STATE}"
  printf '推送告警：\n%s\n' "${msg}"
  alert_send "${msg}" || true
}

# ---------------------------------------------------------------- 主流程
case "${MODE}" in
  probe)
    run_probe
    exit 0
    ;;
  alertcheck)
    alert_check
    exit 0
    ;;
  alerttest)
    need_root
    alert_send "探针告警测试：来自 $(hostname)" && log "测试告警已发出" && exit 0
    die "测试告警未发出，检查 ALERT_TG_TOKEN/ALERT_TG_CHAT 或 ALERT_WEBHOOK"
    ;;
  status)
    show_status
    exit 0
    ;;
  clash)
    set_clash_api "${CLASH_ARG}"
    exit 0
    ;;
  ui)
    install_ui
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
