#!/usr/bin/env bash
# ssh-spa 共用函数。不要单独运行，被 00/10/20-*.sh source。

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "${SKIP_ROOT:-0}" = 1 ] && return 0; [ "$(id -u)" = 0 ] || die "需要 root：sudo bash $0"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1"; }

# 读取 KEY=VALUE 环境文件（只做赋值，不执行其中的命令）
load_env() {
  local f="$1"
  [ -f "$f" ] || die "找不到密钥包：$f"
  set -a; . "$f"; set +a
}

# 名字只允许字母数字 . _ -，因为它会进 grep -E 和 fwknop 的 stanza 名
valid_name() { case "${1:-}" in "" | *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

# 取密钥对 "<KEY_BASE64>:<HMAC_KEY_BASE64>"：
# 传了名字（或文件里有 CLIENT_NAME）就找该客户端，否则回退到 SHARED
# 每客户端的密钥放在一行 CLIENTS="name=k:h other=k:h" 里，
# 不能写成 CLIENT name=... —— 那种行 shell source 不了。
spa_keys_for() {
  local file="$1" name="${2:-}" line entry
  [ -n "$name" ] || name="${CLIENT_NAME:-}"
  if [ -n "$name" ]; then
    line="$(grep -E '^CLIENTS=' "$file" | head -n1 || true)"
    [ -n "$line" ] || die "密钥包里没有 CLIENTS"
    # 值在文件里带引号，base64 字符集不含引号，直接去掉
    for entry in $(printf '%s' "${line#*=}" | tr -d '"'); do
      case "$entry" in
        "$name"=*) printf '%s\n' "${entry#*=}"; return 0 ;;
      esac
    done
    die "密钥包里没有客户端 $name（重新生成时把它写进 --clients）"
  fi
  line="$(grep -E '^SHARED=' "$file" | head -n1 || true)"
  [ -n "$line" ] || die "密钥包里既没有客户端 $name 也没有 SHARED"
  printf '%s\n' "${line#*=}"
}

# 数一个 "a=1 b=2" 形式的值里有几项
host_count() { local v="${1:-}"; [ -n "$v" ] || { echo 0; return; }; set -- $v; echo $#; }

# 32 字节随机 base64，等价于 fwknop --key-gen 的输出格式
gen_key() { openssl rand -base64 32 | tr -d '\n'; }

# ===== SSH 端口探测 =====
# 云厂商给的新机器常是随机端口，不是 22。凭「SSH_PORT 默认 22」去删 ufw 规则，
# 会删一条不存在的规则然后报告成功——端口纹丝不动。所以一律先探测。
# 与 deploy 的 system_detect_ssh_ports() 同一套三路：当前连接 → sshd 监听 → sshd_config

ssh_detect_ports() {
  local p=""
  [ -n "${SSH_CONNECTION:-}" ] && p="$(printf '%s' "$SSH_CONNECTION" | awk '{print $4}')"
  if command -v ss >/dev/null 2>&1; then
    p="$p $(ss -tlnpH 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -u | paste -sd' ' -)"
  fi
  if [ -r /etc/ssh/sshd_config ]; then
    p="$p $(awk 'tolower($1)=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null | sort -u | paste -sd' ' -)"
  fi
  printf '%s\n' $p | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -
}

# 实际使用的 SSH 端口列表 = 探测结果 ∪ 显式指定的 SSH_PORT。
# 探测结果为准：sshd 同时监听多个端口时必须全部处理，只关其中一个的话，
# 另一个还开着、而 SPA 只放行其中之一，等于多开一扇没用的门。
# 显式填的只用于「补上探测不到但你确实知道存在」的端口，不会缩窄探测结果。
# 两边都拿不到 → die，不猜 22。
ssh_resolve_ports() {
  local detected explicit missing="" p
  detected="$(ssh_detect_ports)"
  explicit="${SSH_PORT:-}"
  if [ -n "$detected" ] && [ -n "$explicit" ]; then
    for p in $explicit; do
      printf '%s\n' $detected | grep -qx "$p" || missing="$missing $p"
    done
    if [ -n "$missing" ]; then
      warn "密钥包里填的 SSH_PORT=$explicit 在本机没监听到"
      warn "  本机 sshd 实际监听：${detected}。若 $explicit 确实存在会一并处理，否则以探测结果为准"
    fi
  fi
  if [ -n "$detected" ]; then
    printf '%s\n' $detected $explicit | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -
    return 0
  fi
  if [ -n "$explicit" ]; then printf '%s\n' "$explicit"; return 0; fi
  die "探测不到本机 SSH 端口。请用 SSH_PORT=你的端口 指定（ss -tlnp | grep sshd 可以看）"
}