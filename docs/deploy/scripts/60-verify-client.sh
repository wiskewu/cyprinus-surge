#!/usr/bin/env bash
# 60-verify-client.sh —— 在【客户端机器】做验收测试（用本地 mixed 入站，不需要 TUN）。
# 用法： bash 60-verify-client.sh client.env
#       PROXY=socks5h://127.0.0.1:20122 bash 60-verify-client.sh client.env   # GUI 的端口
#       SERVER_IP=1.2.3.4 VLESS_PORT=443 bash 60-verify-client.sh             # 没 client.env（device.sh 流程）
#
# 设计原则：
#   1) 代理不通就直接停（exit 2），不打印一堆误导性的结果
#   2) 只在拿到真实数据时才记 ✓；空值 / HTTP 000 一律算失败
#   3) 不依赖 nc / mtr / 第三方 IP 回显站
#   4) 走 SOCKS 时 time_connect 只是到本地代理的几毫秒，不能当路径指标
set -uo pipefail   # 验收脚本要跑完全部检查项，故不启用 -e
CLIENT_ENV_FILE="${1:-./client.env}"
ENVFILE="$CLIENT_ENV_FILE"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$SELF_DIR/lib.sh"
# 环境文件可有可无：脚本真正用到的只有 SERVER_IP / VLESS_PORT。
# 用 device.sh 管设备时，客户端手上只有一份 JSON，没必要（也不应该）把 client.env 发过去，
# 这时直接给变量：SERVER_IP=1.2.3.4 VLESS_PORT=443 bash 60-verify-client.sh
if [[ -f "$ENVFILE" ]]; then
  load_env "$ENVFILE"
elif [[ -n "${SERVER_IP:-}" ]]; then
  printf '\033[33m[!]\033[0m 没有 %s，按命令行给的 SERVER_IP / VLESS_PORT 继续\n' "$ENVFILE" >&2
else
  die "找不到 ${ENVFILE}，从服务器 /etc/sing-box/client.env 复制一份，或用 SERVER_IP= VLESS_PORT= 直接给"
fi
SERVER_IP="${SERVER_IP:-}"
VLESS_PORT="${VLESS_PORT:-443}"

PROXY="${PROXY:-socks5h://127.0.0.1:2080}"
PASS=0; FAIL=0; SKIP=0

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
no()   { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '  \033[36m·\033[0m %s\n' "$*"; SKIP=$((SKIP+1)); }
# 只接受数字与小数点，防止把 HTML 之类的东西喂给 printf/awk
num()  { case "${1:-}" in ''|*[!0-9.]*) echo 0 ;; *) echo "$1" ;; esac; }

# 同一个 URL 请求两次：第 1 次冷启动，第 2 次复用连接。
# 注意 -o 是按位置的：两个 URL 就要两个 -o，否则第二个响应正文会打到 stdout。
probe() {
  curl --proxy "$PROXY" -sS --max-time "${2:-25}" \
    -o /dev/null "$1" -o /dev/null "$1" \
    -w '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}\n' \
    2>/dev/null || true
}
# 单个 URL，输出 "<code> <ttfb>"
one() {
  curl --proxy "$PROXY" -sS --max-time "${2:-15}" -o /dev/null \
    -w '%{http_code} %{time_starttransfer}' "$1" 2>/dev/null || true
}
body() {
  curl --proxy "$PROXY" -fsS --max-time "${2:-12}" "$1" 2>/dev/null || true
}

say "0. 本地代理是否可用（${PROXY}）"
first="$(body https://api.ipify.org 12)"
if [[ -z "$first" ]]; then
  printf '  \033[31m✗\033[0m 无法通过 %s 完成任何请求\n' "$PROXY"
  cat <<'EOF'

  代理没起来，后面的检查都会失真，所以这里直接停。按顺序排查：
    1) 客户端核心启动了吗？报 missing tags / duplicate outbound tag 就是没起来
    2) 端口对吗？GUI.for.SingBox 默认 20122，我们自己生成的配置是 2080
    3) 配置里有 mixed 入站吗？手机配置（CLIENT_MIXED=0）只有 TUN，没有本地端口
    4) 换端口跑：PROXY=socks5h://127.0.0.1:端口 bash 60-verify-client.sh client.env
    5) 用 device.sh 管设备时根本没 client.env：SERVER_IP=服务器IP VLESS_PORT=443 bash 60-verify-client.sh
EOF
  exit 2
fi
ok "代理可用，境外出口 $first"
if [[ "$first" == "${SERVER_IP}" ]]; then
  ok "境外流量确实走 VPS（${SERVER_IP}）"
else
  no "境外出口是 ${first}，不是 SERVER_IP=${SERVER_IP}（检查 client.env 与配置是否同源）"
fi

say "1. 分流：国内站点是否直连（A/B 对照，不依赖第三方）"
# 同一条命令跑两次：--noproxy（基线）与走代理，比 ttfb。
# 走 SOCKS 时 time_connect 只是到本地代理的几毫秒，所以只能比 ttfb。
for host in https://www.baidu.com https://www.qq.com; do
  d="$(curl -sS -o /dev/null --noproxy '*' --max-time 12 -w '%{http_code} %{time_starttransfer}' "$host" 2>/dev/null || true)"
  p="$(curl --proxy "$PROXY" -sS -o /dev/null --max-time 12 -w '%{http_code} %{time_starttransfer}' "$host" 2>/dev/null || true)"
  read -r dcode dtfb <<<"$d"
  read -r pcode ptfb <<<"$p"
  dcode="${dcode:-000}"; pcode="${pcode:-000}"
  dtfb="$(num "$dtfb")"; ptfb="$(num "$ptfb")"
  if [[ "$pcode" == "000" ]]; then
    no "$host 经代理不可达（代理自身能通的话，多半是「直连出口」解析失败，见下方 DNS 提示）"
  elif [[ "$dcode" != "000" ]] && awk -v t="$dtfb" 'BEGIN{exit !(t>0)}'; then
    verdict="$(awk -v d="$dtfb" -v p="$ptfb" 'BEGIN{ x=p-d; if (x<0.08 && x>-0.08) print "same"; else if (x>0.20) print "tunnel"; else print "unclear" }')"
    case "$verdict" in
      same)    ok   "$host 直连 ${dtfb}s / 走代理 ${ptfb}s → 分流生效（未绕行）" ;;
      tunnel)  no   "$host 直连 ${dtfb}s / 走代理 ${ptfb}s → 被绕进隧道（多 $(awk -v d="$dtfb" -v p="$ptfb" 'BEGIN{printf "%.0f",(p-d)*1000}')ms）" ;;
      *)       note "$host 直连 ${dtfb}s / 走代理 ${ptfb}s → 差异不明显，看连接列表确认" ;;
    esac
  else
    if awk -v t="$ptfb" 'BEGIN{exit !(t>0 && t<0.15)}'; then
      ok   "$host 走代理 ${ptfb}s → 直连（国内站点通常 20–100ms）"
    elif awk -v t="$ptfb" 'BEGIN{exit !(t>=0.25)}'; then
      no   "$host 走代理 ${ptfb}s → 像被送进隧道（国内站点不应超过 250ms）"
    else
      note "$host 走代理 ${ptfb}s → 拿不到直连基线，无法判定，看连接列表"
    fi
  fi
done
note "100% 确认：看连接列表的 chains（GUI「连接」页，或 Clash API /connections，见 06-ops）"

say "2. 延迟分解（冷启动 vs 复用连接）"
note "同一个 URL 请求两次：第 1 次冷启动，第 2 次复用连接（后者才是浏览体感）"
for host in https://www.google.com https://www.youtube.com; do
  out="$(probe "$host")"
  cold="$(printf '%s\n' "$out" | sed -n '1p')"
  warm="$(printf '%s\n' "$out" | sed -n '2p')"
  read -r c_code c_dns c_local c_tls c_ttfb c_total <<<"$cold"
  w_ttfb="$(printf '%s\n' "$warm" | awk '{print $5}')"
  c_code="${c_code:-000}"
  c_dns="$(num "$c_dns")"; c_local="$(num "$c_local")"; c_tls="$(num "$c_tls")"
  c_ttfb="$(num "$c_ttfb")"; c_total="$(num "$c_total")"; w_ttfb="$(num "$w_ttfb")"
  if [[ "$c_code" == "000" ]] || [[ "$c_ttfb" == "0" ]]; then
    no "$host 请求失败（连不上或 TLS 未完成）"
    continue
  fi
  printf '    \033[2m冷启动 dns=%.3fs 本地=%.3fs TLS完成=%.3fs ttfb=%.3fs total=%.3fs\033[0m\n' \
    "$c_dns" "$c_local" "$c_tls" "$c_ttfb" "$c_total"
  printf '    \033[2m复用连接 ttfb=%.3fs\033[0m\n' "$w_ttfb"
  if awk -v w="$w_ttfb" 'BEGIN{exit !(w>0 && w<0.5)}' && awk -v c="$c_ttfb" 'BEGIN{exit !(c<1.2)}'; then
    ok "$(printf '%-26s' "$host") 复用 ${w_ttfb}s，冷启动 ${c_ttfb}s，HTTP $c_code"
  else
    no "$(printf '%-26s' "$host") 复用 ${w_ttfb}s / 冷启动 ${c_ttfb}s（预期 <0.5s / <1.2s）"
    # 走 SOCKS 时“本地连接”只是到 127.0.0.1 的几毫秒；有意义的是 TLS 完成时间。
    awk -v a="$c_tls" -v t="$c_ttfb" 'BEGIN{
      printf "      定位：TLS 完成 %.0fms（含隧道内 DNS+TCP+TLS），首包再 %.0fms\n", a*1000, (t-a)*1000
      if (a > 0.70) print "      → TLS 阶段偏长：多半是丢包重传或晚高峰拥塞（RTT 130ms 时正常应在 260–520ms）"
      else if ((t-a) > 0.45) print "      → TLS 正常、首包慢：是目标站点或 VPS 出口的问题，不是你的线路"
      else print "      → 两段都正常：冷启动被 DNS+新建连接放大，看复用行即可"
    }'
  fi
done

say "3. DNS 是否被接管"
note "mixed 模式下 DNS 由配置里的 dns 段接管，命令行测不准；请用浏览器打开 dnsleaktest.com 复验"
note "另外：如果同时开着两个代理客户端（如 Clash Verge + GUI.for.SingBox），DNS 会被抢，国内域名会解析失败"

say "4. AI 站点可达性"
read -r code _ <<<"$(one https://chatgpt.com)"
code="${code:-000}"
if [[ "$code" == "000" ]]; then
  no "chatgpt.com 请求失败（根本不是 HTTP 错误，而是没连上）"
elif [[ "$code" == "403" ]] || [[ "$code" == "401" ]] || [[ "$code" == "429" ]]; then
  no "chatgpt.com 返回 $code，连接成功但被风控，需更换 AI 出口"
else
  ok "chatgpt.com 返回 $code"
fi
read -r code _ <<<"$(one https://www.youtube.com)"
code="${code:-000}"
if [[ "$code" == "200" ]]; then ok "youtube.com 200"; else no "youtube.com 返回 $code"; fi

say "5. 到服务器的握手质量（客户端 → VPS）"
# Windows 上的 mtr/ping 可能 "exit 0 但只打一行报错"，所以只能看输出里有没有真实数据
lat_ok=0; try_out=""
if command -v mtr >/dev/null 2>&1; then
  try_out="$(mtr -rwzc 20 -P "${VLESS_PORT:-443}" "$SERVER_IP" 2>&1 || true)"
  if printf '%s' "$try_out" | grep -q 'Loss%'; then
    printf '%s\n' "$try_out" | tail -3 | sed 's/^/  /'; lat_ok=1
  fi
fi
if [[ "$lat_ok" == 0 ]]; then
  for flag in -c -n; do   # -c 用于 GNU/macOS，-n 用于 Windows ping
    try_out="$(ping "$flag" 10 "$SERVER_IP" 2>&1 || true)"
    if printf '%s' "$try_out" | grep -qiE 'ttl=|rtt'; then
      printf '%s\n' "$try_out" | tail -2 | sed 's/^/  /'; lat_ok=1; break
    fi
  done
fi
[[ "$lat_ok" == 0 ]] && note "本机没有可用的 mtr / ping（Windows 上常见，不影响其它验收）"

say "6. 出口是否稳定（连测 5 次）"
ips=""
for _ in 1 2 3 4 5; do
  ip="$(body https://api.ipify.org 10)"
  [[ -n "$ip" ]] && ips="$ips $ip"
done
got="$(tr ' ' '\n' <<<"$ips" | grep -c . || true)"
uniq_n="$(tr ' ' '\n' <<<"$ips" | grep . | sort -u | grep -c . || true)"
if [[ "${got:-0}" -lt 3 ]]; then
  no "5 次里只成功 ${got:-0} 次，网络不稳定"
elif [[ "$uniq_n" -eq 1 ]]; then
  ok "5 次出口一致：$(tr ' ' '\n' <<<"$ips" | grep . | sort -u)"
else
  no "出口 IP 在变，$uniq_n 个不同值：$(tr ' ' '\n' <<<"$ips" | grep . | sort -u | paste -sd' ' -)"
fi

printf '\n通过 %d 项，失败 %d 项，跳过 %d 项\n' "$PASS" "$FAIL" "$SKIP"
if [[ "$FAIL" -eq 0 ]]; then
  printf '\033[32m验收通过。\033[0m\n'
else
  printf '\033[33m有失败项：先看第 0/1 项（代理与分流），再看 06-ops.html 的故障手册。\033[0m\n'
  exit 1
fi
