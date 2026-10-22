#!/usr/bin/env bash
# 生成 deploy.sh：lib.sh + steps/*.sh + onekey/driver.sh 拼接成一个文件。
# 改动请改 steps/ 或 onekey/driver.sh，然后重跑本脚本。
set -euo pipefail
cd "$(dirname "$0")"

OUT="${OUT:-deploy.sh}"
STEPS=()
for f in steps/*.sh; do
  id="$(basename "$f" .sh)"
  STEPS+=("${id#*-}")          # 10-system → system
done
[[ "${#STEPS[@]}" -gt 0 ]] || { printf 'steps/ 为空\n' >&2; exit 1; }

{  
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# shellcheck disable=SC2034  # 步骤元数据与跨文件变量由间接展开读取'
  printf '%s\n' '# ==========================================================================='
  printf '# deploy.sh，一键脚本。自动生成，勿手改。\n'
  printf '#   生成时间：%s\n' "$(date -u +%FT%TZ)"
  printf '%s\n' '#   来源：lib.sh + steps/*.sh + onekey/driver.sh'
  printf '%s\n' '#   重新生成：bash build-onekey.sh'
  printf '%s\n' '# ==========================================================================='
  printf '%s\n' 'set -o pipefail'
  printf 'STEPS=(%s)\n' "${STEPS[*]}"
  printf '\n'
  printf '%s\n' '# ---------------------------- lib.sh ----------------------------'
  # 片段的 shebang 与文件级指令由生成器统一给出，拼接时剔除
  sed -e '1{/^#!/d;}' -e '/^# shellcheck shell=bash$/d' -e '/^# shellcheck disable=SC2034/d' lib.sh
  for f in steps/*.sh; do
    printf '\n'
    printf '# ---------------------------- %s ----------------------------\n' "$(basename "$f")"
    sed -e '/^# shellcheck shell=bash$/d' -e '/^# shellcheck disable=SC2034/d' "$f"
  done
  printf '\n'
  sed -e '/^# shellcheck shell=bash$/d' -e '/^# shellcheck disable=SC2034/d' onekey/driver.sh
} >"$OUT.tmp"

bash -n "$OUT.tmp" || { printf '生成失败：%s 有语法错误\n' "$OUT.tmp" >&2; exit 1; }
mv "$OUT.tmp" "$OUT"
chmod +x "$OUT"
printf '已生成 %s，%d 行，%d 个步骤：%s\n' "$OUT" "$(wc -l <"$OUT")" "${#STEPS[@]}" "${STEPS[*]}"
