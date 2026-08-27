#!/bin/bash
# Build every reference plugin in this dir and symlink it into Overlap's user
# Plugins directory so the app discovers it. Dev convenience only — real plugins
# ship however their author distributes them.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Application Support/Overlap/Plugins"
mkdir -p "$DEST"

for dir in "$HERE"/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/manifest.json" ] || continue

    # Compile main.swift → an executable named by the manifest's "exec".
    if [ -f "$dir/main.swift" ]; then
        exec_name="$(/usr/bin/python3 -c "import json,sys;print(json.load(open('$dir/manifest.json'))['exec'])")"
        echo "building $name → $exec_name"
        ( cd "$dir" && swiftc main.swift -o "$exec_name" )
    fi

    ln -sfn "$dir" "$DEST/$name"
    echo "installed $name → $DEST/$name"
done

echo "done. Plugins in: $DEST"
