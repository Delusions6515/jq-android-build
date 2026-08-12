#!/usr/bin/env python3
"""解析 Google Android 仓库清单, 获取 NDK 稳定版本 / 最新稳定版。

数据来源: https://dl.google.com/android/repository/repository2-3.xml
(Google 官方 Android 仓库清单, 所有 NDK 版本及下载 URL 的权威来源)

用法:
  python3 scripts/ndk.py latest    # 输出最新稳定 NDK r 版本 (如 r29)
  python3 scripts/ndk.py versions  # 输出全部稳定 NDK r 版本 (每行一个, 旧->新)
  python3 scripts/ndk.py --xml <file> latest   # 用本地 XML 文件 (调试/离线)
"""
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

XML_URL = "https://dl.google.com/android/repository/repository2-3.xml"
# 稳定版 zip 命名: android-ndk-r29-linux.zip / android-ndk-r27d-linux.zip
# 预览版 (如 android-ndk-r28-beta1-linux.zip) 不匹配, 自动排除
VER_RE = re.compile(r"android-ndk-(r[0-9]+[a-z]?)-linux\.zip$")


def fetch_xml(path=None):
    if path:
        with open(path) as f:
            return f.read()
    with urllib.request.urlopen(XML_URL, timeout=30) as r:
        return r.read()


def ver_key(v):
    m = re.match(r"r(\d+)([a-z]?)", v)
    major = int(m.group(1))
    letter = m.group(2)
    return (major, ord(letter) if letter else 0)


def parse_versions(xml_data):
    root = ET.fromstring(xml_data)
    vers = set()
    for pkg in root.findall(".//remotePackage"):
        if not (pkg.get("path") or "").startswith("ndk;"):
            continue
        for url_el in pkg.findall(".//archives/archive/complete/url"):
            m = VER_RE.search((url_el.text or "").strip())
            if m:
                vers.add(m.group(1))
    return sorted(vers, key=ver_key)


def main():
    args = sys.argv[1:]
    path = None
    if "--xml" in args:
        i = args.index("--xml")
        path = args[i + 1]
        args = args[:i] + args[i + 2:]
    cmd = args[0] if args else "latest"
    xml_data = fetch_xml(path)
    vers = parse_versions(xml_data)
    if not vers:
        print("未解析到任何 NDK 版本", file=sys.stderr)
        sys.exit(1)
    if cmd == "versions":
        print("\n".join(vers))
    else:  # latest
        print(vers[-1])


if __name__ == "__main__":
    main()
