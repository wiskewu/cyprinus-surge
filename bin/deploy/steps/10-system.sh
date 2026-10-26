# shellcheck shell=bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
# 步骤 10：系统初始化。函数与变量都以 system_ 前缀命名，便于一键脚本内联后不冲突。
system_TITLE="系统初始化（依赖 / BBR / swap / 时间同步 / SSH 加固 / 防火墙）"
system_OPTIONAL=0

# 读 sshd 生效值。判定与诊断走同一条路径：`sshd -T | grep -q` 会在 pipefail 下
# 因 SIGPIPE 误判，也可能在 sshd -T 瞬时失败时给出空结果；两者不一致时就会出现
# 「判定说没生效、诊断却打出正确的值」。
system_sshd_value() {
  local out
  out="$(sshd -T 2>/dev/null || true)"
  [[ -n "${out}" ]] || return 1
  printf '%s\n' "${out}" \
    | awk -v k="${1,,}" 'tolower($1) == k { print $2; exit }'
}

system_check() {
  [[ -f /etc/sysctl.d/99-proxy.conf ]] || return 1
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status 2>/dev/null | grep -q '^Status: active' || return 1
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]] || return 1
  # 有可用公钥时，密码登录必须已经关掉；没有公钥则跳过不算未配置
  # （00-bootstrap 会提示先 ssh-copy-id，不该让 --status 一直报红）
  if [[ "$(system_sshd_value passwordauthentication)" != "no" ]]; then
    system_has_authorized_key && return 1
  fi
  return 0
}

# 是否至少有一个可用的公钥：没有就不许关密码，否则会把人锁在门外
system_has_authorized_key() {
  local f
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -r "${f}" ]] || continue
    grep -qE '^[[:space:]]*ssh-(rsa|ed25519|ecdsa)' "${f}" && return 0
  done
  return 1
}

# 探测 SSH 端口：只算真实在监听的端口。
# 配置文件里的 Port 与 ssh.socket 的 Listen 都可能是「将来才会用」的值，
# 例如 ssh.socket 处于 inactive 时仍会返回 [::]:22，按它放行等于给未开放端口开门。
system_detect_ssh_ports() {
  local listen cand="" p
  command -v ss >/dev/null 2>&1 || return 1
  listen="$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un)"

  # 1) 当前会话用的端口，它必然正在监听
  [[ -n "${SSH_CONNECTION:-}" ]] && cand="$(printf '%s' "${SSH_CONNECTION}" | awk '{print $4}')"
  # 2) sshd 进程实际监听
  cand="${cand} $(ss -tlnpH 2>/dev/null | awk '/users:\(\("sshd"/{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | paste -sd' ' -)"
  # 3) socket 激活：只有 ssh.socket 真在运行时才拿它的 Listen
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    cand="${cand} $(systemctl show ssh.socket -p Listen --value 2>/dev/null \
      | awk '{for(i=1;i<=NF;i++) if ($i ~ /:[0-9]+$/) {n=split($i,a,":"); print a[n]}}' \
      | paste -sd' ' -)"
  fi

  # 统一用监听表过滤，不在表里的一律丢弃
  for p in ${cand}; do
    printf '%s\n' "${listen}" | grep -qx "${p}" && printf '%s\n' "${p}"
  done | sort -un | paste -sd' ' -
}

system_run() {
  local VLESS_PORT="${VLESS_PORT:-443}" HY2_PORT="${HY2_PORT:-8443}"
  local HY2_HOP_END="${HY2_HOP_END:-8447}" SWAP_MB="${SWAP_MB:-1024}" SSH_PORTS DETECTED_SSH_PORTS
  export DEBIAN_FRONTEND=noninteractive

  log "1/8 安装基础软件"
  apt-get update -qq
  apt-get -y -qq install --no-install-recommends \
    ca-certificates curl openssl jq tar unzip ufw fail2ban \
    unattended-upgrades vnstat mtr-tiny dnsutils >/dev/null

  log "2/8 内核参数：BBR + 大缓冲区"
  cat >/etc/sysctl.d/99-proxy.conf <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
SYSCTL
  modprobe tcp_bbr 2>/dev/null || true
  printf '%s\n' tcp_bbr >/etc/modules-load.d/bbr.conf
  sysctl --system >/dev/null

  log "3/8 出站优先 IPv4"
  touch /etc/gai.conf
  grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf || printf '%s\n' 'precedence ::ffff:0:0/96  100' >>/etc/gai.conf

  log "4/8 swap"
  if ! swapon --show | grep -q .; then
    if [[ ! -f /swapfile ]]; then
      fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_MB}" status=none
      chmod 600 /swapfile && mkswap /swapfile >/dev/null
    fi
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || printf '%s\n' '/swapfile none swap sw 0 0' >>/etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null
  fi

  log "5/8 时间同步"
  timedatectl set-timezone UTC
  timedatectl set-ntp true
  systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true

  # 先改 sshd 再收防火墙：万一配置写坏了，防火墙这一步根本不会执行到，
  # 你至少还留着一条能连回来的路（且已连着的会话不受影响）
  log "6/8 SSH 加固：仅公钥登录"
  if system_has_authorized_key; then
    mkdir -p /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/99-proxy.conf <<'SSHEOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
SSHEOF
    # Ubuntu 镜像自带 50-cloud-init.conf 里写着 PasswordAuthentication yes，
    # 而 sshd 对每个关键字取「第一个出现的值」，50 排在 99 前面 → 它赢。
    # 所以必须就地改掉，不能只在 99 里写一遍。
    CI=/etc/ssh/sshd_config.d/50-cloud-init.conf
    if [[ -f "${CI}" ]] && grep -qiE '^[[:space:]]*PasswordAuthentication' "${CI}"; then
      [[ -f "${CI}.orig" ]] || cp -a "${CI}" "${CI}.orig"
      # 用 awk 改写而不是 sed -i 's///I'：I 标志是 GNU 独有，BSD sed 会报错
      awk '{ if (tolower($1) == "passwordauthentication") print "PasswordAuthentication no"; else print }' \
        "${CI}" >"${CI}.tmp" && mv "${CI}.tmp" "${CI}"
    fi
    if sshd -t 2>/dev/null; then
      # restart 失败必须显式报出来：sshd -T 读的是文件，服务没起来也会显示新值
      if ! { systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; }; then
        warn "    ssh 服务重启失败，运行中的 sshd 可能仍是旧策略"
      fi
      systemctl is-active --quiet ssh || systemctl is-active --quiet sshd \
        || warn "    sshd 不在运行，检查 systemctl status ssh"
      # 有些镜像（含部分云厂商自定义镜像）的 sshd_config 压根没有 Include 行，
      # 那我们写的 99-proxy.conf 就是死文件——drop-in 根本不会被读。
      # 补一条 Include 到文件最顶部（sshd 对同一关键字取第一个出现的值），验证不过就回滚。
      SC=/etc/ssh/sshd_config
      if ! sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' \
        && [[ -r "${SC}" ]] && ! grep -qiE '^[[:space:]]*Include[[:space:]]' "${SC}"; then
        warn "    ${SC} 里没有 Include sshd_config.d，drop-in 不会被读；补一条到文件顶部（备份 ${SC}.before-include）"
        [[ -f "${SC}.before-include" ]] || cp -a "${SC}" "${SC}.before-include"
        {
          printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf'
          cat "${SC}.before-include"
        } >"${SC}"
        if sshd -t 2>/dev/null; then
          systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        else
          warn "    补 Include 后 sshd -t 不通过，已回滚（sshd 未重启）"
          cp -a "${SC}.before-include" "${SC}"
        fi
      fi
      if [[ "$(system_sshd_value passwordauthentication)" == "no" ]]; then
        log "    已生效：passwordauthentication no"
      else
        _pwauth="$(system_sshd_value passwordauthentication || printf '读不到')"
        # 说不清楚就给人看证据：现在到底是多少、谁把它设回去的（第一个出现的值赢）
        warn "    未生效，当前生效值：${_pwauth:-读不到}，文件 ${SC}"
        warn "    设置该关键字的位置，drop-in 按文件名排序，靠前的生效："
        grep -rniE --exclude='*.orig' '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication)' \
          "${SC}" /etc/ssh/sshd_config.d 2>/dev/null | while IFS= read -r l; do warn "      ${l}"; done
        warn "    改完执行 sshd -t && systemctl restart ssh"
      fi
    else
      warn "sshd 配置有语法错，已回滚本步改动，sshd 未重启"
      rm -f /etc/ssh/sshd_config.d/99-proxy.conf
      [[ -f "${CI}.orig" ]] && mv "${CI}.orig" "${CI}"
    fi
  else
    warn "没有找到任何 authorized_keys，跳过 SSH 加固：先 ssh-copy-id 装好公钥，再重跑本步"
  fi

  log "7/8 防火墙（绝不假设 SSH 是 22）"
  DETECTED_SSH_PORTS="$(system_detect_ssh_ports)"
  SSH_PORTS="$(printf '%s\n%s\n' "${SSH_PORT:-}" "${DETECTED_SSH_PORTS}" | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -)"
  [[ -n "${SSH_PORTS}" ]] || SSH_PORTS=22
  if [[ -z "${DETECTED_SSH_PORTS}" ]]; then
    warn "    探测不到 sshd 监听端口：由 socket 激活或从控制台登录时如此"
    warn "    下面只按 SSH_PORT='${SSH_PORT:-}' 放行。先确认它就是真实端口，否则这次 ufw 一开，下次就登不进来了："
    warn "      ss -tlnp | grep -E 'sshd|:22'　或　sshd -T | grep -i '^port'"
  elif [[ -n "${SSH_PORT:-}" ]] && ! tr ' ' '\n' <<<"${DETECTED_SSH_PORTS}" | grep -qx "${SSH_PORT}"; then
    warn "    SSH_PORT=${SSH_PORT} 不在本机监听列表里（实际：${DETECTED_SSH_PORTS}），两个都会放行"
    warn "    非本机监听值也会放行，确认 ${SSH_PORT} 不是笔误"
  fi
  log "    SSH 端口：${SSH_PORTS}"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for p in ${SSH_PORTS}; do ufw allow "${p}/tcp" comment 'ssh' >/dev/null; done
  ufw allow "${VLESS_PORT}/tcp" comment 'reality' >/dev/null
  ufw allow "${HY2_PORT}:${HY2_HOP_END}/udp" comment 'hysteria2' >/dev/null
  ufw --force enable >/dev/null

  log "8/8 目录与常驻服务"
  ensure_deploy_dir
  install -d -m 700 /var/lib/sing-box /root/backups
  systemctl enable --now fail2ban vnstat >/dev/null 2>&1 || true
  log "完成：${SSH_PORTS} / ${VLESS_PORT}/tcp / ${HY2_PORT}-${HY2_HOP_END}/udp 已放行"
  warn "云厂商安全组也需放行同样端口，否则部分端口超时"
}

system_uninstall() {
  local VLESS_PORT="${VLESS_PORT:-443}" HY2_PORT="${HY2_PORT:-8443}" HY2_HOP_END="${HY2_HOP_END:-8447}"
  ufw delete allow "${VLESS_PORT}/tcp" >/dev/null 2>&1 || true
  ufw delete allow "${HY2_PORT}:${HY2_HOP_END}/udp" >/dev/null 2>&1 || true
  rm -f /etc/sysctl.d/99-proxy.conf
  rm -f /etc/ssh/sshd_config.d/99-proxy.conf
  [[ -f /etc/ssh/sshd_config.d/50-cloud-init.conf.orig ]] \
    && mv /etc/ssh/sshd_config.d/50-cloud-init.conf.orig /etc/ssh/sshd_config.d/50-cloud-init.conf
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  log "已移除本项目加的 ufw 规则、sysctl 与 SSH 加固（SSH 规则、swap、ufw 开关保持不动）"
}
