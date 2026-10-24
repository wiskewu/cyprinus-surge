#!/usr/bin/env python3
"""按技术文档标准检查页面措辞。

规则来自 docs 写作约定：不写营销词，不用破折号代替冒号与逗号，不用总结
铺垫句与空泛程度词，不用第一人称，不写感叹号。

检查对象是页面源文件：.build/*/pages/*.html 与手写的 docs/*.html。
生成物 docs/**/*.html 不重复检查，它们由源文件构建而来。

豁免：行内出现 <!-- docs-style:ignore --> 时跳过该行；ALLLOW 里的字符串
是外部原话或固定术语，命中前先剔除。
"""

import pathlib
import re
import sys

RULES = {
    "破折号": r"——",
    "营销词": r"强大|极致|完美|无缝|轻松|神器|炸裂|超强|领先|顶级|秒开|保姆级|一键搞定",
    "总结铺垫": r"总之|综上|总的来说|值得一提的是|需要注意的是|不难发现|可以看到|接下来|下面我们|让我们|本文将|本节将",
    "空泛程度词": r"非常|十分|极其|极大地|更好地|更加",
    "泛指引用": r"上述|前述|上一节|下一节|见上文|如下图所示|下面介绍",
    "第一人称": r"我们|你们",
    "感叹号": r"！",
}

# 外部原话与固定搭配：检查前先去掉，避免误报
ALLOW = ("您必须接受我们的服务条款",)

IGNORE = "<!-- docs-style:ignore -->"


def targets() -> list[pathlib.Path]:
    root = pathlib.Path(".")
    files = sorted(root.glob(".build/*/pages/*.html"))
    files += [p for p in (root / "docs").glob("*.html")]
    return files


def main() -> int:
    hits: list[str] = []
    for path in targets():
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if IGNORE in line:
                continue
            text = line
            for allowed in ALLOW:
                text = text.replace(allowed, "")
            text = re.sub(r"<[^>]+>", "", text)
            for name, pattern in RULES.items():
                for m in re.finditer(pattern, text):
                    frag = text[max(0, m.start() - 30): m.end() + 30].strip()
                    hits.append(f"{path}:{lineno} [{name}] …{frag}…")
    if hits:
        print("\n".join(hits), file=sys.stderr)
        print(f"页面措辞 {len(hits)} 处需要处理", file=sys.stderr)
        return 1
    print(f"页面措辞检查通过：{len(targets())} 个源页面")
    return 0


if __name__ == "__main__":
    sys.exit(main())
