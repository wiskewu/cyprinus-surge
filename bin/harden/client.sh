#!/usr/bin/env bash
# bin/harden/client.sh —— 在运维机上准备免密登录：生成或复用 Ed25519 密钥、装公钥、
# 写 ~/.ssh/config 里的 Host 块。
#
#   bash bin/harden/client.sh --host 203.0.113.10 --port 4061 --alias vps-byte --install-server
#   bash bin/harden/client.sh --host 203.0.113.10 --check
#
# 幂等：已有密钥就复用；公钥已在服务器上不重复追加；config 里已有指向同一地址的
# 块就复用它的名字与密钥文件，改名时重写该块而不是再写一份。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/ssh-lib.sh
. "${SELF_DIR}/../lib/ssh-lib.sh"

HOST=""
PORT=""
USER_NAME="root"
ALIAS=""
INSTALL=0
PRUNE=0
ASSUME_YES=0
MODE=apply
DRY=0

CFG="${HOME}/.ssh/config"
DEFAULT_KEY="${HOME}/.ssh/id_ed25519"

usage() {
  cat <<'EOF'
用法：bash bin/harden/client.sh --host <地址> [选项]

  --host ADDR       服务器地址，必填
  --port N          端口；默认取已有配置块的值，没有则 22
  --user NAME       登录用户，默认 root
  --alias NAME      给这台服务器起的名字，写进 ~/.ssh/config 的 Host；不给则复用
                    已有同地址块的名字，都没有时用 vps
  --install-server  把本机公钥追加到服务器的 authorized_keys
  --prune           删掉其它指向同一地址的旧 Host 块（默认先问）
  --yes             不提问，按默认值执行
  --dry-run         只打印将要写的内容，不改任何文件
  --check           只报告本机密钥、指向该地址的配置块与可用性
  -h, --help        显示帮助

~/.ssh/config 里的“服务器名字”由你定，脚本不预设具体值：地址与端口一致就复用，
名字不同时用 --alias 改名，旧块按 --prune 或提示清理。
EOF
}

# ---- 解析 ~/.ssh/config ----
# 单个 Host 块的字段；$1=名称 $2=字段名（大小写不敏感）
config_field() {
  awk -v a="$1" -v k="$2" '
    $1 == "Host" { inb = ($2 == a); next }
    inb && tolower($1) == tolower(k) { print $2; exit }
  ' "${CFG}" 2>/dev/null
}

# 所有指向 HostName+Port 的名称；$1=地址 $2=端口
config_aliases_for() {
  awk -v h="$1" -v p="$2" '
    function flush() {
      if (name != "" && hn == h && (pt == "" ? "22" : pt) == p) print name
    }
    $1 == "Host" { flush(); name = $2; hn = ""; pt = ""; next }
    tolower($1) == "hostname" { hn = $2 }
    tolower($1) == "port" { pt = $2 }
    END { flush() }
  ' "${CFG}" 2>/dev/null
}

# 所有指向同一 HostName 的名称（不限定端口），用于识别换端口的场景
config_aliases_for_host() {
  awk -v h="$1" '
    function flush() { if (name != "" && hn == h) print name ":" (pt == "" ? "22" : pt) }
    $1 == "Host" { flush(); name = $2; hn = ""; pt = ""; next }
    tolower($1) == "hostname" { hn = $2 }
    tolower($1) == "port" { pt = $2 }
    END { flush() }
  ' "${CFG}" 2>/dev/null
}

# 该块当前指向的地址与端口，用于报告不一致
config_endpoint() { # $1=名称
  printf '%s:%s' "$(config_field "$1" hostname)" "$(config_field "$1" port || printf '22')"
}

# 删除一个 Host 块（写入前先备份）
config_drop_alias() {
  local name="$1" tmp
  [[ -f "${CFG}" ]] || return 0
  grep -qxF "Host ${name}" "${CFG}" || return 0
  if [[ "${DRY}" == 1 ]]; then
    printf '会从 %s 里删除 Host %s\n' "${CFG}" "${name}"
    return 0
  fi
  tmp="${CFG}.tmp.$$"
  awk -v a="${name}" '
    $1 == "Host" { skip = ($2 == a) }
    skip { next }
    { print }
  ' "${CFG}" >"${tmp}"
  [[ -s "${tmp}" ]] || printf '# 由 bin/harden/client.sh 维护\n' >"${tmp}"
  cp -a "${CFG}" "${CFG}.bak"
  mv "${tmp}" "${CFG}"
  chmod 600 "${CFG}"
}

config_write_alias() { # $1=名称 $2=地址 $3=端口 $4=用户 $5=密钥
  [[ "${DRY}" == 1 ]] && {
    printf '会写入 %s：\nHost %s\n  HostName %s\n  Port %s\n  User %s\n  IdentityFile %s\n  IdentitiesOnly yes\n' \
      "${CFG}" "$1" "$2" "$3" "$4" "$5"
    return 0
  }
  [[ -f "${CFG}" ]] || printf '# 由 bin/harden/client.sh 维护\n' >"${CFG}"
  {
    printf '\nHost %s\n' "$1"
    printf '  HostName %s\n' "$2"
    printf '  Port %s\n' "$3"
    printf '  User %s\n' "$4"
    printf '  IdentityFile %s\n' "$5"
    printf '  IdentitiesOnly yes\n'
  } >>"${CFG}"
  chmod 600 "${CFG}"
}

confirm() { # $1=提示 $2=默认 y|n
  local ans
  [[ "${ASSUME_YES}" == 1 ]] && return 0
  if [[ "${MODE}" == check ]] || [[ "${DRY}" == 1 ]] || ! ui_has_tty; then
    [[ "${2:-y}" == y ]]
    return
  fi
  printf '%s ' "$1"
  read -r ans || true
  case "${ans:-$2}" in y | Y) return 0 ;; *) return 1 ;; esac
}

# ---- 参数 ----
if [[ $# -eq 0 ]]; then
  if ui_has_tty; then
    ui_ask "服务器地址"
    HOST="${UI_ANSWER}"
    ui_ask "端口" "22"
    PORT="${UI_ANSWER}"
    ui_ask "登录用户" "root"
    USER_NAME="${UI_ANSWER}"
    # 不给默认名字：把命名的决定留给使用者，避免所有机器都叫 vps
    ui_ask "给这台服务器起的名字（写进 ~/.ssh/config 的 Host）"
    ALIAS="${UI_ANSWER}"
    ui_confirm "顺手把公钥装到服务器" y && INSTALL=1
  else
    ui_require_tty
  fi
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      shift
      HOST="${1:?--host 需要地址}"
      ;;
    --port)
      shift
      PORT="${1:?--port 需要端口}"
      ;;
    --user)
      shift
      USER_NAME="${1:?--user 需要用户名}"
      ;;
    --alias)
      shift
      ALIAS="${1:?--alias 需要名字}"
      ;;
    --install-server) INSTALL=1 ;;
    --prune) PRUNE=1 ;;
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY=1 ;;
    --check) MODE=check ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

[[ -n "${HOST}" ]] || die "缺少 --host（--help 看用法）"
case "${ALIAS}" in
  "" | *[!A-Za-z0-9._-]*) [[ -z "${ALIAS}" ]] || die "名字只能含字母数字与 . _ -：${ALIAS}" ;;
esac
install -d -m 700 "${HOME}/.ssh"
[[ -f "${CFG}" ]] || : >>"${CFG}"
chmod 600 "${CFG}"

# ---- 复用：同地址同端口的既有块 ----
PORT="${PORT:-$(awk -v h="${HOST}" '
  $1 == "Host" { inb = 0; next }
  tolower($1) == "hostname" && $2 == h { inb = 1; next }
  inb && tolower($1) == "port" { print $2; exit }
' "${CFG}" 2>/dev/null || true)}"
PORT="${PORT:-22}"

SAME="$(config_aliases_for "${HOST}" "${PORT}")"
REUSE_ALIAS="$(printf '%s\n' "${SAME}" | head -1)"
if [[ -z "${SAME}" ]]; then
  OTHER_PORT="$(config_aliases_for_host "${HOST}")"
  if [[ -n "${OTHER_PORT}" ]]; then
    warn "已有块指向同一地址的其它端口：$(printf '%s' "${OTHER_PORT}" | paste -sd' ' -)"
    warn "端口变更时用 --alias <那个名字> 重跑，脚本会就地改写该块，不会再多写一份"
  fi
fi
if [[ -z "${ALIAS}" ]]; then
  if [[ -n "${REUSE_ALIAS}" ]]; then
    ALIAS="${REUSE_ALIAS}"
    log "复用已有配置名：${ALIAS}（${HOST}:${PORT}）"
  else
    ALIAS="vps"
    log "未指定 --alias，使用默认名字 vps（可用 --alias 改成自己的名字）"
  fi
fi

# 密钥文件：优先沿用同名块里的 IdentityFile，其次是同地址其它块，最后默认 ed25519
KEY="$(config_field "${ALIAS}" identityfile || true)"
if [[ -z "${KEY}" ]]; then
  printf '%s\n' "${SAME}" | while IFS= read -r a; do
    [[ -n "${a}" ]] || continue
    k="$(config_field "${a}" identityfile || true)"
    [[ -n "${k}" ]] && printf '%s\n' "${k}"
  done >"${HOME}/.ssh/.client-key.$$"
  KEY="$(head -1 "${HOME}/.ssh/.client-key.$$" 2>/dev/null || true)"
  rm -f "${HOME}/.ssh/.client-key.$$"
  [[ -n "${KEY}" ]] && log "复用既有配置块里的密钥：${KEY}"
fi
[[ -n "${KEY}" ]] || KEY="${DEFAULT_KEY}"
KEY="${KEY/#\~/${HOME}}"
if [[ "${MODE}" != check ]] && [[ ! -f "${KEY}" ]] && grep -qxF "Host ${ALIAS}" "${CFG}"; then
  warn "Host ${ALIAS} 引用的密钥不存在：${KEY}"
  warn "    将生成新密钥并改写该块；服务器上仍需装这把新公钥（--install-server）"
fi

if [[ "${MODE}" == check ]]; then
  printf '单步入口      : %s\n' "$(basename "$0")"
  printf '目标          : %s@%s:%s\n' "${USER_NAME}" "${HOST}" "${PORT}"
  printf '使用的名字    : %s\n' "${ALIAS}"
  printf '密钥文件      : %s\n' "$([[ -f "${KEY}" ]] && ssh-keygen -lf "${KEY}.pub" 2>/dev/null || printf '%s 不存在' "${KEY}")"
  printf '同名块        : %s\n' "$(grep -qxF "Host ${ALIAS}" "${CFG}" && config_endpoint "${ALIAS}" || printf '不存在')"
  if [[ -n "${SAME}" ]]; then
    printf '指向同一地址的块：\n'
    printf '%s\n' "${SAME}" | sed 's/^/  - /'
    printf '可用性        : %s\n' "$(ssh -F "${CFG}" -o BatchMode=yes -o ConnectTimeout=6 "${REUSE_ALIAS}" true 2>/dev/null && printf '可登录' || printf '登录失败（密钥未装或端口不对）')"
  else
    printf '指向同一地址的块：无\n'
  fi
  exit 0
fi

# ---- 密钥 ----
if [[ ! -f "${KEY}" ]]; then
  if [[ "${DRY}" == 1 ]]; then
    printf '会生成密钥：%s\n' "${KEY}"
  else
    log "生成 Ed25519 密钥 ${KEY}"
    ssh-keygen -t ed25519 -N '' -C "${USER_NAME}@$(hostname)" -f "${KEY}" >/dev/null
  fi
else
  log "复用已有密钥：$(ssh-keygen -lf "${KEY}.pub" 2>/dev/null || printf '%s' "${KEY}")"
fi

# ---- 装公钥 ----
if [[ "${INSTALL}" == 1 ]]; then
  if [[ "${DRY}" == 1 ]]; then
    printf '会把 %s.pub 装到 %s@%s:%s\n' "${KEY}" "${USER_NAME}" "${HOST}" "${PORT}"
  else
    PUB="$(cat "${KEY}.pub")"
    log "把公钥装到 ${USER_NAME}@${HOST}:${PORT}"
    if ssh -p "${PORT}" -o StrictHostKeyChecking=accept-new "${USER_NAME}@${HOST}" \
      "grep -qF '${PUB}' ~/.ssh/authorized_keys 2>/dev/null"; then
      log "    公钥已存在，跳过"
    else
      ssh -p "${PORT}" -o StrictHostKeyChecking=accept-new "${USER_NAME}@${HOST}" \
        "umask 077; mkdir -p ~/.ssh; printf '%s\n' '${PUB}' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"
      log "    已追加"
    fi
  fi
fi

# ---- 写配置：同名块存在则重写（支持改名与改指向），否则追加 ----
EXISTING_SAME=0
grep -qxF "Host ${ALIAS}" "${CFG}" && EXISTING_SAME=1
if [[ "${EXISTING_SAME}" == 1 ]]; then
  OLD_EP="$(config_endpoint "${ALIAS}")"
  OLD_KEY="$(config_field "${ALIAS}" identityfile || true)"
  if [[ "${OLD_EP}" == "${HOST}:${PORT}" ]] && [[ -n "${OLD_KEY}" ]] && [[ "${OLD_KEY//\~/${HOME}}" == "${KEY}" ]]; then
    log "${CFG} 里的 Host ${ALIAS} 已指向 ${HOST}:${PORT}，保持原样"
  else
    log "重写 Host ${ALIAS}：${OLD_EP:-无地址} → ${HOST}:${PORT}（备份 ${CFG}.bak）"
    config_drop_alias "${ALIAS}"
    config_write_alias "${ALIAS}" "${HOST}" "${PORT}" "${USER_NAME}" "${KEY}"
  fi
else
  config_write_alias "${ALIAS}" "${HOST}" "${PORT}" "${USER_NAME}" "${KEY}"
  [[ "${DRY}" == 1 ]] || log "已写入 Host ${ALIAS} → ${USER_NAME}@${HOST}:${PORT}"
fi

# ---- 清理其它指向同一地址的块 ----
printf '%s\n' "${SAME}" | while IFS= read -r a; do
  [[ -n "${a}" ]] || continue
  [[ "${a}" == "${ALIAS}" ]] && continue
  if [[ "${PRUNE}" == 1 ]] || confirm "另有 Host ${a} 也指向 ${HOST}:${PORT}，删掉它吗？[y/N]" n; then
    if [[ "${DRY}" == 1 ]]; then
      printf '会删除 Host %s\n' "${a}"
    else
      config_drop_alias "${a}"
      log "已删除重复的 Host ${a}"
    fi
  else
    warn "保留 Host ${a}：两个名字指向同一地址，容易改错其中一个"
  fi
done

if [[ "${DRY}" == 1 ]]; then
  log "DRY_RUN：未改动任何文件"
  exit 0
fi

log "验证免密登录"
if ssh -F "${CFG}" -o BatchMode=yes -o ConnectTimeout=10 "${ALIAS}" true 2>/dev/null; then
  log "    成功：ssh ${ALIAS}"
else
  warn "    失败：确认服务器已装公钥、端口 ${PORT} 可达、用户名 ${USER_NAME} 正确"
  warn "    服务器上核对：grep -c '^ssh-' ~/.ssh/authorized_keys"
  exit 1
fi
