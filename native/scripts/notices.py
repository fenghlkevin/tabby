#!/usr/bin/env python3
"""Collect pinned dependencies' root license and notice files into the app."""
from pathlib import Path
import sys, shutil
root, output = Path(sys.argv[1]), Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
for checkout in sorted((root / '.build/checkouts').iterdir()):
    for item in checkout.iterdir():
        if item.is_file() and item.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
            destination = output / checkout.name
            destination.mkdir(exist_ok=True)
            target = destination / item.name
            if target.exists(): target.chmod(target.stat().st_mode | 0o200)
            shutil.copy2(item, target)
shutil.copy2(root / 'Package.resolved', output / 'Package.resolved')
shutil.copy2(root.parent / 'LICENSE', output / 'Tabby-LICENSE')
# Terminal palettes are data assets rather than Swift package dependencies.
theme_licenses = root / 'Resources/ThemeLicenses'
if theme_licenses.exists():
    destination = output / 'TerminalThemes'
    destination.mkdir(exist_ok=True)
    for item in sorted(theme_licenses.iterdir()):
        if item.is_file():
            target = destination / item.name
            if target.exists(): target.chmod(target.stat().st_mode | 0o200)
            shutil.copy2(item, target)
