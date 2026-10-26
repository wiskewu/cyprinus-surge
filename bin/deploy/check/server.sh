#!/usr/bin/env bash
# bin/deploy/check/server.sh —— 服务端自检：进程、监听、日志、时间、BBR、伪装站点、IP 一致性。
# 用法： sudo bash bin/deploy/check/server.sh
set -uo pipefail # 自检脚本要跑完全部检查项，故不启用 -e
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"
load_env "${ENVFILE}"

# 缺变量时给出人话，而不是 "unbound variable"
for v in SERVER_IP VLESS_PORT REALITY_DEST; do
  [[ -n "${!v:-}" ]] || die "deploy.env 缺少 ${v}，重跑 bin/deploy/one/secrets.sh 或补一行 ${v}="
done

ok=0
bad=0
chk() { # chk "名称" "命令" "期望片段"
  local name="$1" out="$2" want="${3:-}"
  if [[ -n "${want}" ]]; then
    if printf '%s' "${out}" | grep -q -- "${want}"; then
      printf '  \033[32m✓\033[0m %s\n' "${name}"
      ok=$((ok + 1))
    else
      printf '  \033[31m✗\033[0m %s → %s\n' "${name}" "$(printf '%s' "${out}" | head -1)"
      bad=$((bad + 1))
    fi
  else
    printf '  \033[32m✓\033[0m %s → %s\n' "${name}" "${out}"
    ok=$((ok + 1))
  fi
}

printf '== 1. 进程与监听 ==\n'
chk "sing-box 运行中" "$(systemctl is-active sing-box)" "active"
chk "TCP ${VLESS_PORT} 在监听" "$(ss -tlnp 2>/dev/null | grep -c ":${VLESS_PORT} ")" "1"
[[ "${ENABLE_HY2:-0}" == "1" ]] && chk "UDP ${HY2_PORT} 在监听" "$(ss -ulnp 2>/dev/null | grep -c ":${HY2_PORT} ")" "1"

printf '== 2. 配置与日志 ==\n'
chk "配置已落盘" "$(test -s "${DEPLOY_DIR}/config.json" && printf yes)" "yes"

# 日志判定：把 REALITY 的认证噪声单独统计，不算故障。
# 稳健性设计：只取最近 N 行（不做全量时间范围扫描，避免大日志卡住）；
# 每一步都能失败而不影响主流程，避免整个自检静默退出。
log_tail() { journalctl -u sing-box -n "${1:-2000}" --no-pager 2>/dev/null || true; }

errs="$(log_tail 300 | grep -Ei 'error|fatal' \
  | grep -v 'REALITY: processed invalid connection' | tail -3 || true)"
if [[ -n "${errs}" ]]; then
  printf '  \033[33m!\033[0m 日志里有错误：\n%s\n' "${errs}"
else
  printf '  \033[32m✓\033[0m 最近日志无 error（已排除 REALITY 认证噪声）\n'
fi

noise_report() {
  local total ips
  total="$(log_tail 2000 | grep -c 'REALITY: processed invalid connection' || true)"
  case "${total}" in '' | *[!0-9]*) total=0 ;; esac
  [[ "${total}" -gt 0 ]] || return 0
  printf '  \033[36m·\033[0m 最近 2000 行日志里 REALITY 认证失败 %s 次（扫描器噪声，已转发到伪装站点）\n' "${total}"
  ips="$(log_tail 2000 | grep 'REALITY: processed invalid connection' \
    | grep -oE 'from [^ ]+' | sed -e 's/^from //' -e 's/:$//' -e 's/:[0-9]*$//' \
    | sort | uniq -c | sort -rn | head -3)"
  [[ -n "${ips}" ]] && printf '%s\n' "${ips}" | while read -r n ip; do printf '      来源 %s（%s 次）\n' "${ip}" "${n}"; done
  printf '      出现本机宽带 IP 且客户端连不上说明参数不匹配，其他 IP 可忽略\n'
}
(noise_report) || true

printf '== 3. 系统状态 ==\n'
chk "拥塞控制" "$(sysctl -n net.ipv4.tcp_congestion_control)" "bbr"
chk "时间同步" "$(timedatectl show -p NTP --value)" "yes"
skew="$(timedatectl show -p NTPSynchronized --value)"
chk "已与 NTP 同步" "${skew}" "yes"
out_ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
chk "出站 IPv4（应等于 deploy.env 里的 SERVER_IP）" "${out_ip}" "${SERVER_IP}"

printf '== 4. REALITY 伪装站点是否合格 ==\n'
tls="$(timeout 12 openssl s_client -connect "${REALITY_DEST}:443" -servername "${REALITY_DEST}" -tls1_3 -alpn h2 </dev/null 2>/dev/null)"
chk "支持 TLS1.3" "$(printf '%s' "${tls}" | grep -o 'TLSv1.3' | head -1)" "TLSv1.3"
chk "支持 HTTP/2" "$(printf '%s' "${tls}" | grep -o 'ALPN protocol: h2' | head -1)" "h2"
chk "证书链可信" "$(printf '%s' "${tls}" | grep -o 'Verify return code: 0 (ok)' | head -1)" "0 (ok)"

if [[ "${ENABLE_HY2:-0}" == "1" ]]; then
  printf '== 5. Hysteria2 证书 ==\n'
  end="$(timeout 5 openssl x509 -in "${DEPLOY_DIR}/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
  days=$((($(date -d "${end}" +%s) - $(date +%s)) / 86400))
  chk "证书有效期（剩余 ${days} 天）" "$([[ "${days}" -gt 20 ]] && printf ok || printf soon)"
fi

printf '\n'
printf '通过 %s 项，失败 %s 项\n' "${ok}" "${bad}"
[[ "${bad}" -eq 0 ]] || warn "有失败项，排查见 06-ops.html"
