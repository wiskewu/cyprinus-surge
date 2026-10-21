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