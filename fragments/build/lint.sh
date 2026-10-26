#!/usr/bin/env bash
# 对仓库内所有 shell 脚本跑 shellcheck，默认严重级，-x 跟进 source 的片段；
# 另查「变量名紧跟多字节字符」这类 bash 3.2 会误解析的写法。
# npm run lint 调用本脚本；直接 bash .build/lint.sh 亦可。
set -euo pipefail
cd "$(dirname "$0")/../.."

files=()
while IFS= read -r f; do files+=("${f}"); done < <(find bin fragments/build -name '*.sh' | sort)
[[ "${#files[@]}" -gt 0 ]] || { printf '未找到脚本\n' >&2; exit 1; }

# require-variable-braces 把所有 $var 收紧成 ${var}：一是排版统一，
# 二是避免 bash 3.2 把紧跟的多字节字符并入变量名。
opts=(-x -o require-variable-braces)
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${opts[@]}" "${files[@]}"
else
  npx --yes shellcheck "${opts[@]}" "${files[@]}"
fi
printf 'shellcheck 通过：%d 个文件\n' "${#files[@]}"

# 布局统一：两空格缩进、case 分支缩进、二元运算符前置。
# 不加 -kp：它会把一行里的多条语句按原列宽摊开，case 分支会变成阶梯缩进。
# 改完跑 shfmt -i 2 -ci -bn -w <文件>。
if command -v shfmt >/dev/null 2>&1; then
  unformatted="$(shfmt -i 2 -ci -bn -l "${files[@]}")"
  if [[ -n "${unformatted}" ]]; then
    printf '以下脚本格式与 shfmt 不一致：\n%s\n跑 shfmt -i 2 -ci -bn -w 修\n' "${unformatted}" >&2
    exit 1
  fi
  printf 'shfmt 格式检查通过：%d 个文件\n' "${#files[@]}"
else
  printf '未找到 shfmt，跳过格式检查（brew install shfmt）\n'
fi

# bash 3.2 按字节扫变量名：变量后紧跟中文标点时会被并入变量名。
# Python 侧统一用 uv 管理：有 uv 就用 uv 跑，没有则退回 python3。
PY=()
if command -v uv >/dev/null 2>&1; then
  PY=(uv run --quiet python)
elif command -v python3 >/dev/null 2>&1; then
  PY=(python3)
fi
if [[ "${#PY[@]}" -gt 0 ]]; then
  "${PY[@]}" fragments/build/check-var-braces.py "${files[@]}"
  # 页面措辞：不写营销词、破折号、总结铺垫句、第一人称与感叹号
  "${PY[@]}" fragments/build/check-docs-style.py
else
  printf '未找到 uv 或 python3，跳过变量边界与页面措辞检查\n'
fi
