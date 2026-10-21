import fs from 'node:fs';
const p = 'docs/deploy/scripts/60-verify-client.sh';
let s = fs.readFileSync(p, 'utf8');

// 1) 每个 URL 各配一个 -o，否则第二个 URL 的正文会打到 stdout（被当成数字 → printf 报错）
s = s.replace(
`probe() {
  curl --proxy "$PROXY" -sS -o /dev/null --max-time "\${2:-25}" \
    -w '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}\n' \
    "$1" "$1" 2>/dev/null || true
}`,
`probe() {
  # 注意：-o 是按位置的，两个 URL 就要两个 -o；否则第二个响应正文会打到 stdout
  curl --proxy "$PROXY" -sS --max-time "\${2:-25}" \
    -o /dev/null "$1" -o /dev/null "$1" \
    -w '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}\n' \
    2>/dev/null || true
}
# 只保留数字和小数点，防止把 HTML 之类的东西喂给 printf/awk
num() { case "\${1:-}" in ''|*[!0-9.]*) echo 0 ;; *) echo "$1" ;; esac; }`);

// 2) conn() 不再用 time_connect（SOCKS 下它只是到本地代理的 4ms），改用 ttfb
s = s.replace(
`# 走代理请求单个 URL，输出 "<code> <tcp> <ttfb>"；失败时 code 为 000
conn() {
  curl --proxy "$PROXY" -sS -o /dev/null --max-time "\${2:-12}" \
    -w '%{http_code} %{time_connect} %{time_starttransfer}' "$1" 2>/dev/null || true
}`,
`# 走代理请求单个 URL，输出 "<code> <ttfb>"；失败时 code 为 000
conn() {
  curl --proxy "$PROXY" -sS -o /dev/null --max-time "\${2:-12}" \
    -w '%{http_code} %{time_starttransfer}' "$1" 2>/dev/null || true
}`);

// 3) 第 1 段：A/B 比较 ttfb（time_connect 在 SOCKS 下无意义）
s = s.replace(
`  d="$(curl -sS -o /dev/null --noproxy '*' --max-time 12 -w '%{http_code} %{time_connect}' "$host" 2>/dev/null || true)"
  p="$(curl --proxy "$PROXY" -sS -o /dev/null --max-time 12 -w '%{http_code} %{time_connect}' "$host" 2>/dev/null || true)"
  read -r dcode dtcp <<< "$d"
  read -r pcode ptcp <<< "$p"
  dcode="\${dcode:-000}"; pcode="\${pcode:-000}"`,
`  # 比 ttfb，不比 time_connect：走 SOCKS 时 time_connect 只是到本地代理的几毫秒，没有意义
  d="$(curl -sS -o /dev/null --noproxy '*' --max-time 12 -w '%{http_code} %{time_starttransfer}' "$host" 2>/dev/null || true)"
  p="$(curl --proxy "$PROXY" -sS -o /dev/null --max-time 12 -w '%{http_code} %{time_starttransfer}' "$host" 2>/dev/null || true)"
  read -r dcode dtcp <<< "$d"
  read -r pcode ptcp <<< "$p"
  dcode="\${dcode:-000}"; pcode="\${pcode:-000}"; dtcp="$(num "$dtcp")"; ptcp="$(num "$ptcp")"`);

s = s.replace(/(\s+)(same\)    ok "\$host 直连基线 tcp=)/g, '$1$2');
s = s.replace(/直连基线 tcp=\$\{dtcp\}s，走代理 tcp=\$\{ptcp\}s/g, '直连基线 ttfb=${dtcp}s，走代理 ttfb=${ptcp}s');
s = s.replace(/走代理 tcp=\$\{ptcp\}s/g, '走代理 ttfb=${ptcp}s');
s = s.replace(/\(\$host 走代理 tcp=/g, '($host 走代理 ttfb=');

// 阈值适配 ttfb：直连国内站点通常 20–100ms，绕美国 ≥2×RTT(260ms)
s = s.replace(
`    verdict="$(awk -v d="$dtcp" -v p="$ptcp" 'BEGIN{ x=p-d; if (x<0.05 && x>-0.05) print "same"; else if (x>0.15) print "tunnel"; else print "unclear" }')"`,
`    verdict="$(awk -v d="$dtcp" -v p="$ptcp" 'BEGIN{ x=p-d; if (x<0.08 && x>-0.08) print "same"; else if (x>0.20) print "tunnel"; else print "unclear" }')"`);

s = s.replace(
`    if awk -v t="$ptcp" 'BEGIN{exit !(t>0 && t<0.10)}'; then
      ok "$host 走代理 ttfb=\${ptcp}s → 直连（国内握手通常 10–60ms）"
    elif awk -v t="$ptcp" 'BEGIN{exit !(t>=0.25)}'; then`,
`    if awk -v t="$ptcp" 'BEGIN{exit !(t>0 && t<0.15)}'; then
      ok "$host 走代理 ttfb=\${ptcp}s → 直连（国内站点通常 20–100ms）"
    elif awk -v t="$ptcp" 'BEGIN{exit !(t>=0.25)}'; then`);

// 4) 第 2 段：数字净化 + 定位逻辑改成基于 appconnect（tcp 是本地 4ms）
s = s.replace(
`  read -r c_code c_dns c_tcp c_tls c_ttfb c_total <<< "$cold"
  w_ttfb="$(printf '%s\n' "$warm" | awk '{print $5}')"
  printf '    \033[2m冷启动  dns=%.3fs tcp=%.3fs tls=%.3fs ttfb=%.3fs total=%.3fs\033[0m\n' \
    "$c_dns" "$c_tcp" "$c_tls" "$c_ttfb" "$c_total"
  printf '    \033[2m复用连接 ttfb=%.3fs\033[0m\n' "\${w_ttfb:-0}"`,
`  read -r c_code c_dns c_tcp c_tls c_ttfb c_total <<< "$cold"
  w_ttfb="$(printf '%s\n' "$warm" | awk '{print $5}')"
  c_code="\${c_code:-000}"; c_dns="$(num "$c_dns")"; c_tcp="$(num "$c_tcp")"
  c_tls="$(num "$c_tls")"; c_ttfb="$(num "$c_ttfb")"; c_total="$(num "$c_total")"
  w_ttfb="$(num "$w_ttfb")"
  printf '    \033[2m冷启动  dns=%.3fs 本地连接=%.3fs TLS完成=%.3fs ttfb=%.3fs total=%.3fs\033[0m\n' \
    "$c_dns" "$c_tcp" "$c_tls" "$c_ttfb" "$c_total"
  printf '    \033[2m复用连接 ttfb=%.3fs\033[0m\n' "$w_ttfb"`);

s = s.replace(
`  if awk -v w="\${w_ttfb:-9}" 'BEGIN{exit !(w>0 && w<0.5)}' && awk -v c="$c_ttfb" 'BEGIN{exit !(c<1.2)}'; then
    ok "$(printf '%-26s' "$host") 复用 ttfb=\${w_ttfb}s，冷启动 \${c_ttfb}s，HTTP $c_code"
  else
    no "$(printf '%-26s' "$host") 复用 ttfb=\${w_ttfb}s / 冷启动 \${c_ttfb}s（预期 <0.5s / <1.2s）"
    # 自动定位：与 ICMP RTT 对比（第 5 段会测）
    awk -v t="$c_tcp" -v l="$c_tls" 'BEGIN{
      printf "      定位：tcp %.0fms，tls 额外 %.0fms\n", t*1000, (l-t)*1000
      if (t > 0.35) print "      → TCP 握手就慢：对比第 5 段 RTT，若 tcp 远大于 RTT 则有丢包/MTU 问题"
      else if ((l-t) > 0.45) print "      → TLS 耗时偏大：多见于丢包重传，或用 -k 排除证书吊销检查"
      else print "      → 握手正常，慢在服务端或首包：冷启动受 DNS+新连接放大，看复用行即可"
    }'
  fi`,
`  if awk -v w="$w_ttfb" 'BEGIN{exit !(w>0 && w<0.5)}' && awk -v c="$c_ttfb" 'BEGIN{exit !(c<1.2)}'; then
    ok "$(printf '%-26s' "$host") 复用 ttfb=\${w_ttfb}s，冷启动 \${c_ttfb}s，HTTP $c_code"
  else
    no "$(printf '%-26s' "$host") 复用 ttfb=\${w_ttfb}s / 冷启动 \${c_ttfb}s（预期 <0.5s / <1.2s）"
    # 走 SOCKS 时“本地连接时间”只是到 127.0.0.1 的几毫秒，没有诊断价值；
    # 真正有意义的是 TLS 完成时间（含隧道内的 DNS+TCP+TLS）和 ttfb-TLS。
    awk -v a="$c_tls" -v t="$c_ttfb" 'BEGIN{
      printf "      定位：TLS 完成 %.0fms（含隧道内 DNS+TCP+TLS），首包再 %.0fms\n", a*1000, (t-a)*1000
      if (a > 0.70) print "      → TLS 阶段偏长：多半是丢包重传，或晚高峰拥塞（第 5 段 RTT 仅 130ms 时正常应在 260–520ms）"
      else if ((t-a) > 0.45) print "      → TLS 正常、首包慢：是目标站点或 VPS 出口的问题，不是你的线路"
      else print "      → 两段都正常：冷启动被 DNS+新建连接放大，看复用行即可"
    }'
  fi`);

fs.writeFileSync(p, s);
console.log('patched');
