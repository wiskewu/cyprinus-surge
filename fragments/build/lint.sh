#!/usr/bin/env bash
# 对仓库内所有 shell 脚本跑 shellcheck，默认严重级，-x 跟进 source 的片段；
# 另查「变量名紧跟多字节字符」这类 bash 3.2 会误解析的写法。
# npm run lint 调用本脚本；直接 bash fragments/build/lint.sh 亦可。
# 依赖：shellcheck（本地或 npx）、node 与 @wasm-fmt/shfmt（npm devDependencies）。
set -euo pipefail
cd "$(dirname "$0")/../.."

files=()
while IFS= read -r f; do files+=("${f}"); done < <(find bin fragments/build -name '*.sh' | sort)
[[ "${#files[@]}" -gt 0 ]] || {
  printf '未找到脚本\n' >&2
  exit 1
}

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
# 用 shfmt 的 WASM 版本，不依赖原生二进制；改格式跑 node fragments/build/format-sh.mjs <文件>。
node fragments/build/check-format.mjs

# bash 3.2 按字节扫变量名，变量后紧跟中文标点会被并入变量名。
node fragments/build/check-var-braces.mjs "${files[@]}"

# 页面措辞：不写营销词、破折号、总结铺垫句、第一人称与感叹号。
node fragments/build/check-docs-style.mjs
