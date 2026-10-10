#!/usr/bin/env python3
from __future__ import annotations
from datetime import datetime
from pathlib import Path
import re
import shutil
import sys

overlay = Path(__file__).resolve().parent
target = Path(sys.argv[1] if len(sys.argv) > 1 else "/volume1/web/subweb")
index_path = target / "index.html"
if not index_path.is_file():
    raise SystemExit(f"index file not found: {index_path}")

required = [
    "vendor/jquery/jquery-3.6.4.min.js",
    "vendor/fontawesome/css/all.min.css",
    "vendor/fontawesome/webfonts/fa-brands-400.woff2",
    "vendor/fontawesome/webfonts/fa-regular-400.woff2",
    "vendor/fontawesome/webfonts/fa-solid-900.woff2",
    "vendor/inter/inter.css",
    "vendor/inter/inter-latin-ext.woff2",
    "vendor/inter/inter-latin.woff2",
]
missing_assets = [name for name in required if not (overlay / name).is_file()]
if missing_assets:
    raise SystemExit("overlay assets missing: " + ", ".join(missing_assets))

shutil.copytree(overlay / "vendor", target / "vendor", dirs_exist_ok=True)
source = index_path.read_text(encoding="utf-8")
updated = source
rules = [
    ("jquery", re.compile(r'<script\b(?=[^>]*\bsrc=["\']https://unpkg\.com/jquery@[^"\']+/dist/jquery(?:\.min)?\.js["\'])[^>]*></script>', re.I), '<script defer="defer" src="./vendor/jquery/jquery-3.6.4.min.js"></script>', "./vendor/jquery/jquery-3.6.4.min.js"),
    ("inter", re.compile(r'<link\b(?=[^>]*\bhref=["\']https://fonts\.googleapis\.com/css2\?family=Inter[^"\']*["\'])[^>]*>', re.I), '<link href="./vendor/inter/inter.css" rel="stylesheet">', "./vendor/inter/inter.css"),
    ("fontawesome", re.compile(r'<link\b(?=[^>]*\bhref=["\']https://cdnjs\.cloudflare\.com/ajax/libs/font-awesome/[^"\']+/css/all\.min\.css["\'])[^>]*>', re.I), '<link rel="stylesheet" href="./vendor/fontawesome/css/all.min.css">', "./vendor/fontawesome/css/all.min.css"),
]
messages = []
for name, pattern, replacement, marker in rules:
    updated, count = pattern.subn(replacement, updated)
    if count:
        messages.append(f"{name}: replaced {count} remote reference(s)")
    elif marker in updated:
        messages.append(f"{name}: already local")
    else:
        raise SystemExit(f"{name} reference not found; inspect new upstream HTML")

updated, count = re.subn(r'<script\s+src=["\']\./qrcode\.min\.js["\']\s*></script>', '<script defer="defer" src="./qrcode.min.js"></script>', updated, flags=re.I)
if count:
    messages.append("qrcode: changed to deferred loading")

for forbidden in ("unpkg.com/jquery", "fonts.googleapis.com/css2?family=Inter", "cdnjs.cloudflare.com/ajax/libs/font-awesome"):
    if forbidden in updated:
        raise SystemExit(f"remote reference remains: {forbidden}")

if updated != source:
    backup_dir = target / "backup-local-assets"
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup_path = backup_dir / ("index.html." + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(index_path, backup_path)
    index_path.write_text(updated, encoding="utf-8")
    messages.extend((f"backup: {backup_path}", f"updated: {index_path}"))
else:
    messages.append("index: no change required")

for path in (target / "vendor").rglob("*"):
    path.chmod(0o755 if path.is_dir() else 0o644)
print("\n".join(messages))
print(f"local asset overlay applied to {target}")
