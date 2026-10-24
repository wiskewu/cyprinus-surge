#!/usr/bin/env bash
# ssh-spa 共用函数。不要单独运行，被 00/10/20-*.sh source。

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ "${SKIP_ROOT:-0}" == 1 ]] && return 0; [[ "$(id -u)" == 0 ]] || die "需要 root：sudo bash $0"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1"; }

# ---- 临时目录：集中登记，脚本退出时统一清理 ----
# 直接写 TMP="$(mktemp -d)" 的话，die 或中断退出会把目录留在 /tmp。用 mktemp_dir
# 取目录，再在入口脚本里 trap cleanup_tmp_dirs EXIT。
_TMP_DIRS=()
cleanup_tmp_dirs() {
  local d
  for d in ${_TMP_DIRS[@]+"${_TMP_DIRS[@]}"}; do
    [[ -n "${d}" ]] && rm -rf "${d}"
  done
  _TMP_DIRS=()
  return 0
}
# 用法：mktemp_dir VAR —— 建目录、登记到退出清理表，结果写进 VAR。
# 不用 $(mktemp_dir) 取值：命令替换在子 shell 里跑，登记表加了也传不出来。
mktemp_dir() {
  local _d
  [[ -n "${1:-}" ]] || die "mktemp_dir 需要一个变量名"
  _d="$(mktemp -d)"
  _TMP_DIRS+=("${_d}")
  printf -v "$1" '%s' "${_d}"
}

# 读取 KEY=VALUE 环境文件（只做赋值，不执行其中的命令）
load_env() {
  local f="$1"
  [[ -f "${f}" ]] || die "找不到密钥包：${f}"
  set -a
  # shellcheck disable=SC1090  # 路径来自参数
  . "${f}"
  set +a
}

# 名字只允许字母数字 . _ -，因为它会进 grep -E 和 fwknop 的 stanza 名
valid_name() { case "${1:-}" in "" | *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

# 取密钥对 "<KEY_BASE64>:<HMAC_KEY_BASE64>"：
# 传了名字（或文件里有 CLIENT_NAME）就找该客户端，否则回退到 SHARED
# 每客户端的密钥放在一行 CLIENTS="name=k:h other=k:h" 里，
# 不能写成 CLIENT name=... —— 那种行 shell source 不了。
spa_keys_for() {
  local file="$1" name="${2:-}" line entry
  [[ -n "${name}" ]] || name="${CLIENT_NAME:-}"
  if [[ -n "${name}" ]]; then
    line="$(grep -E '^CLIENTS=' "${file}" | head -n1 || true)"
    [[ -n "${line}" ]] || die "密钥包里没有 CLIENTS"
    # 值在文件里带引号，base64 字符集不含引号，直接去掉
    for entry in $(printf '%s' "${line#*=}" | tr -d '"'); do
      case "${entry}" in
        "${name}"=*) printf '%s\n' "${entry#*=}"; return 0 ;;
      esac
    done
    die "密钥包里没有客户端 ${name}，重新生成时写进 --clients"
  fi
  line="$(grep -E '^SHARED=' "${file}" | head -n1 || true)"
  [[ -n "${line}" ]] || die "密钥包里既没有客户端 ${name} 也没有 SHARED"
  printf '%s\n' "${line#*=}"
}

# 数一个 "a=1 b=2" 形式的值里有几项
host_count() { local v="${1:-}"; [[ -n "${v}" ]] || { printf '0
'; return; }; read -r -a _w <<<"${v}"; printf '%s
' "${#_w[@]}"; }

# 32 字节随机 base64，等价于 fwknop --key-gen 的输出格式
gen_key() { openssl rand -base64 32 | tr -d '\n'; }

# ===== SSH 端口探测 =====
# 云厂商给的新机器常是随机端口，不是 22。凭「SSH_PORT 默认 22」去删 ufw 规则，
# 会删一条不存在的规则然后报告成功——端口纹丝不动。所以一律先探测。
# 与 deploy 的 system_detect_ssh_ports() 同一套：当前连接 → sshd 监听 → ssh.socket → sshd_config

ssh_detect_ports() {
  local p=""
  [[ -n "${SSH_CONNECTION:-}" ]] && p="$(printf '%s' "${SSH_CONNECTION}" | awk '{print $4}')"
  if command -v ss >/dev/null 2>&1; then
    p="${p} $(ss -tlnpH 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -u | paste -sd' ' -)"
  fi
  # sshd 由 socket 激活时（ssh.socket），监听套接字是 systemd 的、进程名不叫 sshd，
  # 按进程名 grep 会整个拿不到，只能问 systemd 要 ListenStream
  if command -v systemctl >/dev/null 2>&1; then
    p="${p} $(systemctl show ssh.socket -p Listen --value 2>/dev/null \
      | awk '{for(i=1;i<=NF;i++) if ($i ~ /:[0-9]+$/) {n=split($i,a,":"); print a[n]}}' \
      | sort -u | paste -sd' ' -)"
  fi
  if [[ -r /etc/ssh/sshd_config ]]; then
    p="${p} $(awk 'tolower($1)=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null | sort -u | paste -sd' ' -)"
  fi
  tr ' ' '\n' <<<"${p}" | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -
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
  if [[ -n "${detected}" ]] && [[ -n "${explicit}" ]]; then
    for p in ${explicit}; do
      tr ' ' '\n' <<<"${detected}" | grep -qx "${p}" || missing="${missing} ${p}"
    done
    if [[ -n "${missing}" ]]; then
      warn "密钥包里的 SSH_PORT=${explicit} 在本机未监听"
      warn "  本机 sshd 监听 ${detected}，两者都会处理"
    fi
  fi
  if [[ -n "${detected}" ]]; then
    { tr ' ' '\n' <<<"${detected}"; tr ' ' '\n' <<<"${explicit}"; } | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -
    return 0
  fi
  if [[ -n "${explicit}" ]]; then printf '%s\n' "${explicit}"; return 0; fi
  die "探测不到本机 SSH 端口，用 SSH_PORT=<端口> 指定，取值见 ss -tlnp"
}