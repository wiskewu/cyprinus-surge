#!/usr/bin/env bash
# 00-gen-keys.sh —— 生成 SPA 密钥包。
#   产出两份东西：
#     spa-keys.env       服务端用（含全部客户端密钥）
#     clients/<name>.env 每台客户端一份（只含自己的那对密钥）
#   密钥格式与 `fwknop --key-gen` 一致：KEY_BASE64 + HMAC_KEY_BASE64。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "${SELF_DIR}/lib.sh"
need_cmd openssl

OUT="spa-keys.env"
CLIENTS=""
HOSTS=""
SHARED=0
FORCE=0
MODE=generate
SPLIT=""
# 客户端与服务端的 HMAC 摘要算法必须一致：fwknopd 的 stanza 不写这一项时固定按
# SHA256 校验，客户端若声明 SHA512 就会永久报 Non-corresponding HMAC。
HMAC_DIGEST="SHA512"
CLIENTS_DIR="clients"

usage() {
  cat <<'EOF'
用法：bash 00-gen-keys.sh [选项]

  --out FILE            密钥包路径（默认 spa-keys.env）
  --hosts "h1=ip h2=host"  这批密钥管哪些主机（写进客户端配置，按名字分段）
  --clients "laptop phone" 每台客户端一个独立密钥，可单独吊销（推荐）
  --shared              只生成一组共用密钥，所有客户端相同（简单，但吊销一个要全换）
  --split FILE          从已有服务端密钥包拆出客户端包，不重新生成密钥
  --clients-dir DIR     拆分输出目录（默认 clients）
  --force               覆盖已存在的密钥包
  -h, --help            显示帮助

例：
  bash 00-gen-keys.sh --hosts "server1=203.0.113.10" --clients "laptop phone"
  bash 00-gen-keys.sh --split spa-keys.env --clients-dir clients
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      shift
      OUT="${1:?--out 需要参数}"
      ;;
    --out=*) OUT="${1#*=}" ;;
    --hosts)
      shift
      HOSTS="${1:?--hosts 需要参数}"
      ;;
    --hosts=*) HOSTS="${1#*=}" ;;
    --clients)
      shift
      CLIENTS="${1:?--clients 需要参数}"
      ;;
    --clients=*) CLIENTS="${1#*=}" ;;
    --shared) SHARED=1 ;;
    --split)
      shift
      MODE="split"
      SPLIT="${1:?--split 需要参数}"
      ;;
    --split=*)
      MODE="split"
      SPLIT="${1#*=}"
      ;;
    --clients-dir)
      shift
      CLIENTS_DIR="${1:?--clients-dir 需要参数}"
      ;;
    --clients-dir=*) CLIENTS_DIR="${1#*=}" ;;
    --force) FORCE=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
  shift
done

if [[ "${MODE}" == generate ]]; then
  [[ "${SHARED}" == 1 ]] || [[ -n "${CLIENTS}" ]] || {
    usage
    die "--clients 和 --shared 至少给一个"
  }
  [[ "${SHARED}" == 1 ]] && [[ -n "${CLIENTS}" ]] && die "--clients 与 --shared 二选一"
fi
CLIENTS_ARG="${CLIENTS}" # 固定下来：load_env 之后 CLIENTS 会被密钥包里的同名变量覆盖

if [[ "${MODE}" == generate ]] && [[ -e "${OUT}" ]] && [[ "${FORCE}" != 1 ]]; then
  die "${OUT} 已存在。确认要覆盖（旧的密钥会失效）就加 --force"
fi

umask 077
OUT_DIR="$(dirname "${OUT}")"
mkdir -p "${OUT_DIR}/clients"

# --- 参数校验：主机名格式和客户端名字都要能安全进 grep/sed ---
if [[ -n "${HOSTS}" ]]; then
  for h in ${HOSTS}; do
    case "${h}" in
      *=?*) valid_name "${h%%=*}" || die "主机名不合法：${h}（只允许字母数字 . _ -）" ;;
      *) die "主机条目要写成 name=地址：${h}" ;;
    esac
  done
fi
if [[ -n "${CLIENTS_ARG}" ]]; then
  for c in ${CLIENTS_ARG}; do
    valid_name "${c}" || die "客户端名不合法：${c}（只允许字母数字 . _ -）"
  done
fi

STAMP="$(date -u +%FT%TZ)"
HEADER="# ssh-spa 密钥包 · 生成于 ${STAMP}
# chmod 600：含可直接开你服务器的口令，不要提交进 git、不要贴进聊天窗口。
# 用法：拷给服务端 → 10-server.sh --keys；拷给客户端 → 20-client.sh --keys。
"

write_bundle() {
  # $1=输出文件 $2=该文件专属的键值行（SHARED=… / CLIENTS="…"）
  # SSH_PORT 不在这里猜：密钥包往往在另一台机器上生成，那时无从知道服务器的真实端口。
  # 服务端跑 10-server.sh 时会探测并回写 client.env；这里只保留用户显式指定的值。
  local sshline=""
  [[ -n "${SSH_PORT:-}" ]] && sshline="SSH_PORT=\"${SSH_PORT}\""
  cat >"$1" <<EOF
${HEADER}
SPA_PORT=62201
${sshline:-# SSH_PORT 由服务端 10-server.sh 探测后写入 client.env}
ACCESS_TIMEOUT=120
MAX_FW_TIMEOUT=300
HMAC_DIGEST_TYPE=${HMAC_DIGEST}
HOSTS="${HOSTS}"
$2
EOF
  chmod 600 "$1"
}

# --- 拆分模式：从已有的服务端密钥包还原客户端包，密钥不变 ---
# 典型场景：只有服务器上还留着 spa-keys.env，本地那份 clients/ 已经没了。
# 重新生成要换密钥（服务端 access.conf 也得重写），拆分只做拷贝。
emit_split_client() {
  # $1=输出文件 $2=该文件专属的键值行（SHARED=… / CLIENT_NAME + CLIENTS）
  local out="$1" kv="$2" tmp="$1.tmp" sshline=""
  [[ -n "${SSH_PORT:-}" ]] && sshline="SSH_PORT=\"${SSH_PORT}\""
  {
    printf '%s\n' "# ssh-spa 密钥包 · 拆分于 ${STAMP}，密钥来自 ${SPLIT_SRC}，未重新生成" \
      "# chmod 600：含可直接开你服务器的口令，不要提交进 git、不要贴进聊天窗口。" \
      "# 用法：拷给客户端 → 20-client.sh --keys。" \
      "" \
      "SPA_PORT=${SPA_PORT:-62201}" \
      "${sshline:-# SSH_PORT 未知：用服务端 10-server.sh 探测后回写的值}" \
      "ACCESS_TIMEOUT=${ACCESS_TIMEOUT:-120}" \
      "MAX_FW_TIMEOUT=${MAX_FW_TIMEOUT:-300}" \
      "HMAC_DIGEST_TYPE=${HMAC_DIGEST_TYPE:-${HMAC_DIGEST}}" \
      "HOSTS=\"${HOSTS:-}\""
    printf '%s\n' "${kv}"
  } >"${tmp}"
  chmod 600 "${tmp}"
  if [[ -f "${out}" ]] && cmp -s "${out}" "${tmp}"; then
    rm -f "${tmp}"
    log "${out} 与密钥包一致，未改写"
  else
    mv "${tmp}" "${out}"
    log "客户端包 → ${out}"
  fi
}

run_split() {
  local src="$1" entry name pair got
  local -a entries
  [[ -f "${src}" ]] || die "找不到密钥包：${src}"
  SPLIT_SRC="${src}"
  # 清掉生成模式的默认值，否则 SHARED=0 会被当成「源文件里有 SHARED」
  SHARED=""
  CLIENTS=""
  load_env "${src}"
  mkdir -p "${CLIENTS_DIR}"

  if [[ -n "${SHARED:-}" ]]; then
    emit_split_client "${CLIENTS_DIR}/shared.env" "SHARED=${SHARED}"
    return 0
  fi
  [[ -n "${CLIENTS:-}" ]] || die "${src} 里既没有 CLIENTS 也没有 SHARED"

  read -r -a entries <<<"${CLIENTS}"
  for entry in "${entries[@]}"; do
    name="${entry%%=*}"
    pair="${entry#*=}"
    valid_name "${name}" || die "客户端名不合法：${name}"
    case "${pair}" in
      *:*) ;;
      *) die "客户端 ${name} 的密钥对格式不对：缺 : 分隔" ;;
    esac
    emit_split_client "${CLIENTS_DIR}/${name}.env" "CLIENT_NAME=${name}
CLIENTS=\"${name}=${pair}\""
    got="$(spa_keys_for "${CLIENTS_DIR}/${name}.env" "${name}")"
    [[ "${got}" == "${pair}" ]] || die "自检失败：${name} 写回后密钥对不一致"
  done
  log "共 $(host_count "${CLIENTS}") 份客户端包，密钥与 ${src} 一致"
}

if [[ "${MODE}" == "split" ]]; then
  run_split "${SPLIT}"
  exit 0
fi

log "生成密钥"
if [[ "${SHARED}" == 1 ]]; then
  pair="$(gen_key):$(gen_key)" # 服务端包和客户端包必须用同一对
  write_bundle "${OUT}" "SHARED=${pair}"
  write_bundle "${OUT_DIR}/clients/shared.env" "SHARED=${pair}"
  log "共用密钥 → ${OUT} 与 ${OUT_DIR}/clients/shared.env（两份内容一致）"
else
  ENTRIES=""
  for c in ${CLIENTS_ARG}; do
    pair="$(gen_key):$(gen_key)" # 一台客户端一对密钥，服务端包和客户端包必须用同一对
    ENTRIES="${ENTRIES:+${ENTRIES} }${c}=${pair}"
    write_bundle "${OUT_DIR}/clients/${c}.env" "CLIENT_NAME=${c}
CLIENTS=\"${c}=${pair}\""
    log "客户端 ${c} → ${OUT_DIR}/clients/${c}.env"
  done
  write_bundle "${OUT}" "CLIENTS=\"${ENTRIES}\""
  log "服务端包 → ${OUT}"
fi

# --- 自检：写出来的文件要能被 source 回去，密钥条数要对得上 ---
load_env "${OUT}"
if [[ -n "${CLIENTS_ARG}" ]]; then
  want="$(host_count "${CLIENTS_ARG}")"
  got="$(host_count "${CLIENTS:-}")"
  [[ "${got}" == "${want}" ]] || die "自检失败：${OUT} 里 ${got} 条客户端密钥，期望 ${want} 条"
  for c in ${CLIENTS_ARG}; do
    pair="$(spa_keys_for "${OUT}" "${c}")"
    case "${pair}" in
      *:*) [[ -n "${pair%%:*}" ]] && [[ -n "${pair##*:}" ]] || die "自检失败：客户端 ${c} 密钥对不完整" ;;
      *) die "自检失败：客户端 ${c} 的密钥对格式不对" ;;
    esac
  done
else
  spa_keys_for "${OUT}" >/dev/null || die "自检失败：SHARED 取不到"
fi

log "自检通过"
cat <<EOF

下一步：
  1) 服务端：scp ${OUT} root@<服务器>:/root/ && ssh root@<服务器> 'bash 10-server.sh --keys /root/$(basename "${OUT}")'
     （先别加 --close-ssh，见 README「避免把自己锁在门外」）
  2) 客户端：scp ${OUT_DIR}/clients/<名字>.env <机器>:~/ && 在那台机器上 bash 20-client.sh --keys ~/<名字>.env
     （每台机器只需要自己那一份，不需要 spa-keys.env）
EOF
