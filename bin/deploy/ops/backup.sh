#!/usr/bin/env bash
# bin/deploy/ops/backup.sh —— 备份与恢复 sing-box 的全部东西（配置、密钥、证书、systemd 单元）。
#
#   sudo bash bin/deploy/ops/backup.sh backup     新建备份，默认加密
#   sudo bash bin/deploy/ops/backup.sh list       列出备份
#   sudo bash bin/deploy/ops/backup.sh restore F  从备份恢复
#   sudo bash bin/deploy/ops/backup.sh key        查看或生成备份口令文件
#
# 加密优先 gpg --symmetric，缺失时退回 openssl enc；两者都没有则拒绝生成明文包，
# 除非显式加 --insecure。口令默认放 /root/.backup-passphrase（600），需离线另存一份。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"
need_root
BK_DIR="${BK_DIR:-/root/backups}"
PASS_FILE="${BACKUP_PASSPHRASE_FILE:-/root/.backup-passphrase}"
INSECURE=0
install -d -m 700 "${BK_DIR}"

case "${1:-}" in
  -h | --help)
    cat <<'EOF'
用法：sudo bash bin/deploy/ops/backup.sh <动作> [选项]

  backup            新建备份，默认 gpg 加密，缺 gpg 时用 openssl
  list              列出备份，标注明文还是加密
  restore <文件>    从备份恢复并重启 sing-box
  key               查看或生成备份口令文件

  --insecure        backup 时跳过加密，产物为明文 .tgz
EOF
    exit 0
    ;;
esac

if [[ $# -eq 0 ]]; then
  if ui_has_tty; then
    actions=(
      "backup|新建备份（默认加密）"
      "list|列出已有备份"
      "restore|从指定备份恢复"
      "key|查看或生成备份口令"
    )
    ui_menu "备份与恢复" "${actions[@]}"
    set -- "${UI_CHOICE}"
    if [[ "${UI_CHOICE}" == "restore" ]]; then
      ui_ask "备份文件路径"
      set -- restore "${UI_ANSWER}"
    fi
  else
    set -- backup
  fi
fi

# 允许把 --insecure 放在任意位置
args=()
for a in "$@"; do
  case "${a}" in
    --insecure) INSECURE=1 ;;
    *) args+=("${a}") ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

ensure_pass_file() {
  [[ -s "${PASS_FILE}" ]] || die "缺少口令文件 ${PASS_FILE}，先跑 bin/deploy/ops/backup.sh key 生成"
}

# 口令只在本机生成一次；丢了口令，加密包就打不开
show_or_make_key() {
  if [[ -s "${PASS_FILE}" ]]; then
    printf '口令文件：%s（%s 字节）\n' "${PASS_FILE}" "$(wc -c <"${PASS_FILE}" | tr -d ' ')"
    warn "离线另存一份。口令丢了，加密备份无法恢复。"
    return 0
  fi
  umask 077
  openssl rand -base64 32 | tr -d '\n' >"${PASS_FILE}"
  chmod 600 "${PASS_FILE}"
  printf '已生成口令文件：%s\n内容如下，请另存到离线位置：\n' "${PASS_FILE}"
  cat "${PASS_FILE}"
  printf '\n'
}

# 加密用 gpg 优先，缺失时退回 openssl enc；两者都支持非交互口令
encrypt_to() { # $1=明文 $2=输出；成功返回 0
  local src="$1" dst="$2" enc="$3"
  case "${enc}" in
    gpg)
      gpg --batch --yes --quiet --pinentry-mode loopback \
        --passphrase-file "${PASS_FILE}" --symmetric --cipher-algo AES256 \
        -o "${dst}" "${src}" || return 1
      ;;
    openssl)
      openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
        -in "${src}" -out "${dst}" -pass "file:${PASS_FILE}" || return 1
      ;;
  esac
  rm -f "${src}"
  return 0
}

decrypt_to() { # $1=密文 $2=输出明文
  local src="$1" dst="$2"
  case "${src}" in
    *.gpg)
      command -v gpg >/dev/null 2>&1 || die "需要 gpg 才能解密 ${src}"
      gpg --batch --yes --quiet --pinentry-mode loopback \
        --passphrase-file "${PASS_FILE}" --decrypt -o "${dst}" "${src}"
      ;;
    *.enc)
      command -v openssl >/dev/null 2>&1 || die "需要 openssl 才能解密 ${src}"
      openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
        -in "${src}" -out "${dst}" -pass "file:${PASS_FILE}"
      ;;
    *.tgz) cp "${src}" "${dst}" ;;
    *) die "认不出备份格式：${src}" ;;
  esac
}

do_backup() {
  local stamp plain
  stamp="$(date +%F-%H%M%S)"
  plain="${BK_DIR}/sing-box-${stamp}.tar"
  tar -cf "${plain}" -C / etc/sing-box etc/systemd/system/sing-box.service 2>/dev/null
  chmod 600 "${plain}"

  if [[ "${INSECURE}" == 1 ]]; then
    mv "${plain}" "${BK_DIR}/sing-box-${stamp}.tgz"
    log "已备份（未加密）：${BK_DIR}/sing-box-${stamp}.tgz"
    warn "包里有 REALITY 私钥，未加密的包不要放到任何外部存储。"
    return 0
  fi

  ensure_pass_file
  if command -v gpg >/dev/null 2>&1 && encrypt_to "${plain}" "${BK_DIR}/sing-box-${stamp}.tgz.gpg" gpg; then
    log "已备份（gpg 加密）：${BK_DIR}/sing-box-${stamp}.tgz.gpg"
  elif command -v openssl >/dev/null 2>&1 && encrypt_to "${plain}" "${BK_DIR}/sing-box-${stamp}.tgz.enc" openssl; then
    log "已备份（openssl 加密）：${BK_DIR}/sing-box-${stamp}.tgz.enc"
  else
    rm -f "${plain}"
    die "没有 gpg 也没有 openssl，拒绝生成明文备份；确需明文加 --insecure"
  fi
  warn "口令在 ${PASS_FILE}，口令丢失则备份无法恢复。"
}

do_list() {
  local f kind found=0
  for f in "${BK_DIR}"/sing-box-*; do
    [[ -f "${f}" ]] || continue
    found=1
    case "${f}" in
      *.tgz) kind="明文" ;;
      *.gpg | *.enc) kind="加密" ;;
      *) kind="格式未知，建议删除" ;;
    esac
    printf '%-46s %s  %s\n' "$(basename "${f}")" "$(du -h "${f}" | cut -f1)" "${kind}"
  done
  [[ "${found}" == 1 ]] || printf '无备份\n'
}

do_restore() {
  local src="${1:-}" T
  [[ -n "${src}" && -f "${src}" ]] || die "用法：bash bin/deploy/ops/backup.sh restore <文件>"
  [[ -s "${src}" ]] || die "备份文件为空：${src}"
  if [[ "${src}" != *.tgz ]]; then
    ensure_pass_file
  fi
  mktemp_dir T
  decrypt_to "${src}" "${T}/backup.tar"
  systemctl stop sing-box 2>/dev/null || true
  tar -xf "${T}/backup.tar" -C /
  systemctl daemon-reload
  systemctl restart sing-box
  log "已恢复并重启：${src}"
  systemctl is-active sing-box
}

case "${1:-backup}" in
  backup) do_backup ;;
  list) do_list ;;
  restore) do_restore "${2:-}" ;;
  key) show_or_make_key ;;
  *) die "用法：bash bin/deploy/ops/backup.sh backup|list|restore <文件>|key" ;;
esac
