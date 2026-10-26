#!/usr/bin/env bash
# 通用 SSH 加固脚本的共用函数。被 ssh-server.sh / ssh-client.sh / ssh-audit.sh
# source，不单独运行，也不改动调用方的 shell 选项。
# 日志、root 检查与交互组件统一由 common.sh 提供
# shellcheck source=SCRIPTDIR/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DROPIN="${DROPIN:-/etc/ssh/sshd_config.d/99-ssh-hardening.conf}"
SSHD_MAIN="${SSHD_MAIN:-/etc/ssh/sshd_config}"
SSHD_DROPIN_DIR="${SSHD_DROPIN_DIR:-/etc/ssh/sshd_config.d}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/ssh-hardening}"
F2B_JAIL="${F2B_JAIL:-/etc/fail2ban/jail.d/sshd-local.conf}"

# sshd 实际端口，不假设 22
ssh_port() {
  local p=""
  if command -v sshd >/dev/null 2>&1; then
    p="$(sshd -T 2>/dev/null | awk 'tolower($1) == "port" { print $2; exit }')"
  fi
  [[ -n "${p}" ]] || p="${SSH_PORT:-22}"
  printf '%s' "${p}"
}

sshd_get() { sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1) == k { print $2; exit }'; }

# 当前会话是否用公钥登录：靠 journal 里与本次连接源端口匹配的 Accepted publickey 记录
session_is_pubkey() {
  local cip cport out
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  # SSH_CONNECTION 的字段顺序是「客户端 IP 客户端端口 服务端 IP 服务端端口」
  read -r cip cport _ _ <<<"${SSH_CONNECTION}"
  # 先取全文再匹配：journalctl 接 grep -q 会因 SIGPIPE 返回非 0，
  # 在 pipefail 下会被当成「找不到记录」。
  out="$(journalctl -u ssh --since "-30 min" --no-pager 2>/dev/null || true)"
  grep -q "Accepted publickey for .* from ${cip} port ${cport}" <<<"${out}"
}

# 统计可用于登录的公钥数（root 与 sudo 用户的 authorized_keys）
count_authorized_keys() {
  local n=0 u home
  for u in root "${SUDO_USER:-}"; do
    [[ -n "${u}" ]] || continue
    home="$(getent passwd "${u}" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "${home}" ]] || continue
    if [[ -s "${home}/.ssh/authorized_keys" ]]; then
      n=$((n + $(grep -cE '^(ssh-|ecdsa-|sk-)' "${home}/.ssh/authorized_keys" || true)))
    fi
  done
  printf '%s' "${n}"
}

# ---------------------------------------------------------------- authorized_keys
# 公钥文件位置：root 与被 sudo 调起的用户，去重后输出
authorized_key_files() {
  local u home
  for u in root "${SUDO_USER:-}"; do
    [[ -n "${u}" ]] || continue
    home="$(getent passwd "${u}" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "${home}" ]] || continue
    [[ -f "${home}/.ssh/authorized_keys" ]] && printf '%s\n' "${home}/.ssh/authorized_keys"
  done | sort -u
}

# 逐把列出：指纹、类型、注释、文件:行号。ssh-copy-id 与各工具追加的行都能看到。
list_authorized_keys() {
  local f line n type b64 comment fp
  while IFS= read -r f; do
    n=0
    while IFS= read -r line; do
      n=$((n + 1))
      case "${line}" in "" | \#*) continue ;; esac
      type="$(printf '%s' "${line}" | awk '{print $1}')"
      b64="$(printf '%s' "${line}" | awk '{print $2}')"
      comment="$(printf '%s' "${line}" | awk '{print $3}')"
      [[ -n "${b64}" ]] || continue
      fp="$(printf '%s %s\n' "${type}" "${b64}" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
      printf '%s\t%s\t%s\t%s:%s\n' "${fp:-未知}" "${type}" "${comment:--}" "${f}" "${n}"
    done <"${f}"
  done < <(authorized_key_files)
}

# 重复的公钥数量：按密钥材料比较，同一把公钥被追加两次算一条
duplicate_authorized_keys() {
  local f
  while IFS= read -r f; do
    awk '{ if ($0 ~ /^[[:space:]]*#/ || NF < 2) next; print $2 }' "${f}" | sort | uniq -d
  done < <(authorized_key_files) | wc -l | tr -d ' '
}

# 去重：同一把公钥只保留第一次出现，其余行删掉；改动前备份为 .bak
dedupe_authorized_keys() {
  local f tmp before after
  while IFS= read -r f; do
    before="$(grep -c . "${f}" 2>/dev/null || printf '0')"
    tmp="${f}.tmp.$$"
    awk '
      { if ($0 ~ /^[[:space:]]*#/ || NF < 2) { print; next } if (seen[$2]++) next; print }
    ' "${f}" >"${tmp}"
    after="$(grep -c . "${tmp}" || printf '0')"
    if [[ "${before}" == "${after}" ]]; then
      rm -f "${tmp}"
      continue
    fi
    cp -a "${f}" "${f}.bak"
    mv "${tmp}" "${f}"
    chmod 600 "${f}"
    log "    ${f}：${before} 行 → ${after} 行（备份 ${f}.bak）"
  done < <(authorized_key_files)
}

# sshd 对同一关键字取第一个出现的值，Include 按文件名排序就地展开
sshd_uses_dropin() { grep -qiE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "${SSHD_MAIN}" 2>/dev/null; }

first_file_with_key() {
  local key="$1" f
  if sshd_uses_dropin; then
    for f in "${SSHD_DROPIN_DIR}"/*.conf; do
      [[ -f "${f}" ]] || continue
      [[ "${f}" == "${DROPIN}" ]] && continue
      grep -qiE "^[[:space:]]*${key}[[:space:]]" "${f}" && {
        printf '%s\n' "${f}"
        return 0
      }
    done
  fi
  grep -qiE "^[[:space:]]*${key}[[:space:]]" "${SSHD_MAIN}" && {
    printf '%s\n' "${SSHD_MAIN}"
    return 0
  }
  return 1
}

# 就地改写「第一个出现」的那一行，避免被排序更靠前的文件压过
set_sshd_key() {
  local key="$1" val="$2" f=""
  f="$(first_file_with_key "${key}" || true)"
  [[ -n "${f}" ]] || return 0
  awk -v k="${key}" -v v="${val}" '
    BEGIN { done = 0 }
    { if (!done && tolower($1) == tolower(k)) { print k " " v; done = 1; next } print }
  ' "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
  chmod 644 "${f}" 2>/dev/null || true
  log "    ${f} → ${key} ${val}"
}
