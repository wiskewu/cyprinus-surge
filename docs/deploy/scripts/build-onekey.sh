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
[ "${#STEPS[@]}" -gt 0 ] || { echo "steps/ 为空" >&2; exit 1; }

{
  echo '#!/usr/bin/env bash'
  echo '# ==========================================================================='
  echo '# deploy.sh —— 一键脚本（自动生成，勿手改）'
  echo "#   生成时间：$(date -u +%FT%TZ)"
  echo '#   来源：lib.sh + steps/*.sh + onekey/driver.sh'
  echo '#   重新生成：bash build-onekey.sh'
  echo '# ==========================================================================='
  echo 'set -o pipefail'
  printf 'STEPS=(%s)\n' "${STEPS[*]}"
  echo
  echo '# ---------------------------- lib.sh ----------------------------'
  sed '1{/^#!/d;}' lib.sh    # 用 BSD sed 也认的写法（macOS 本地重算 deploy.sh 不至于卡住）
  for f in steps/*.sh; do
    echo
    echo "# ---------------------------- $(basename "$f") ----------------------------"
    cat "$f"
  done
  echo
  cat onekey/driver.sh
} >"$OUT.tmp"

bash -n "$OUT.tmp" || { echo "生成失败：$OUT.tmp 有语法错误" >&2; exit 1; }
mv "$OUT.tmp" "$OUT"
chmod +x "$OUT"
printf '已生成 %s（%d 行，%d 个步骤：%s）\n' "$OUT" "$(wc -l <"$OUT")" "${#STEPS[@]}" "${STEPS[*]}"
