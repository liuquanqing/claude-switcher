#!/usr/bin/env python3

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_PATH = ROOT / "docs" / "功能对比数据.json"
TEMPLATE_PATH = ROOT / "docs" / "功能对比说明.template.html"
OUTPUT_PATH = ROOT / "docs" / "功能对比说明.html"
MARKER = "__FEATURE_DATA__"


def embed_json(data):
    serialized = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return (
        serialized.replace("&", "\\u0026")
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")
    )


def main():
    with DATA_PATH.open(encoding="utf-8") as source:
        data = json.load(source)
    if not isinstance(data, dict):
        raise ValueError("功能对比数据的顶层必须是 JSON 对象")

    template = TEMPLATE_PATH.read_text(encoding="utf-8")
    if template.count(MARKER) != 1:
        raise ValueError(f"模板必须且只能包含一个 {MARKER} 标记")

    output = template.replace(MARKER, embed_json(data))
    OUTPUT_PATH.write_text(output, encoding="utf-8")
    print(f"已生成 {OUTPUT_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
