#!/usr/bin/env python3
"""Check one validation journal and optionally seal its reviewed prefix."""
import argparse
from datetime import date
import hashlib
import json
from pathlib import Path
import sys


def verify(journal, root):
    data = journal.read_bytes()
    lines = data.splitlines(keepends=True)
    if not lines or not data.endswith(b"\n"):
        raise ValueError("台账为空或最后一条记录缺少换行")
    rows = []
    seen = set()
    for number, line in enumerate(lines, 1):
        try:
            row = json.loads(line)
            for key in ("id", "date", "scope", "type", "actor", "summary"):
                if not isinstance(row[key], str) or not row[key].strip():
                    raise ValueError(f"{key} 应为非空文本")
            date.fromisoformat(row["date"])
            if row["id"] in seen:
                raise ValueError("事件编号重复")
            if not isinstance(row["builds"], list) or any(type(i) is not int or i < 1 for i in row["builds"]):
                raise ValueError("builds 应为构建号数组")
            related = row["related"]
            if not isinstance(related, list) or any(r not in seen for r in related):
                raise ValueError("related 只能引用已出现的事件")
            if not isinstance(row["evidence"], list) or not row["evidence"]:
                raise ValueError("缺少证据出处")
            for item in row["evidence"]:
                path = Path(item)
                full = (root / path).resolve()
                if path.is_absolute() or not full.is_relative_to(root) or not full.is_file():
                    raise ValueError(f"证据文件未找到或超出项目目录 {item}")
            if "limitations" not in row:
                raise ValueError("缺少 limitations 字段")
        except (KeyError, ValueError, TypeError) as exc:
            raise ValueError(f"第 {number} 行，{exc}") from exc
        rows.append(row)
        seen.add(row["id"])
    checkpoints = journal.parent / "checkpoints"
    for record in sorted(checkpoints.glob("*.json")):
        checkpoint = json.loads(record.read_text())
        count = checkpoint["events"]
        if type(count) is not int or not 1 <= count <= len(lines):
            raise ValueError(f"历史记录数量与检查点不符 {record.name}")
        digest = hashlib.sha256(b"".join(lines[:count])).hexdigest()
        if digest != checkpoint["sha256"]:
            raise ValueError(f"已核验的记录发生变动 {record.name}")
    return rows, data, checkpoints


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("journal", type=Path)
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="证据路径的工作区根目录")
    parser.add_argument("--seal", action="store_true", help="为当前已复核的事件保存 SHA-256 检查点")
    parser.add_argument("--build", type=int, help="显示指定构建的事件")
    options = parser.parse_args()
    rows, data, checkpoints = verify(options.journal, options.root.resolve())
    if options.seal:
        checkpoints.mkdir(exist_ok=True)
        file = checkpoints / f"{len(rows):06d}.json"
        if not file.exists():
            with file.open("x", encoding="utf-8") as output:
                json.dump({"events": len(rows), "sha256": hashlib.sha256(data).hexdigest()}, output, indent=2)
                output.write("\n")
    print(f"{len(rows)} 条记录通过结构、引用与已有检查点核验")
    if options.build:
        for row in rows:
            if options.build in row["builds"]:
                print(f"{row['id']}  {row['type']}  {row['summary']}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as error:
        sys.exit(str(error))
