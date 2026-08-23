#!/usr/bin/env bash
#
# remap-tags.sh — migrate Finder tags in a folder tree from one naming
# scheme to another, driven by a CSV of `original,new` pairs.
#
# For every file carrying an `original` tag, the tag is removed and the
# matching `new` tag added. 1:1 and reversible (swap the CSV columns to undo).
#
# Usage:
#   ./scripts/remap-tags.sh                 # dry run (default) — shows counts, no writes
#   ./scripts/remap-tags.sh --apply         # actually rewrite tags
#   CSV=~/path.csv ROOT=~/Pictures ./scripts/remap-tags.sh --apply
#
set -euo pipefail

CSV="${CSV:-$HOME/Downloads/tag-remap.csv}"
ROOT="${ROOT:-$HOME/Pictures}"
APPLY=0
if [[ "${1:-}" == "--apply" ]]; then
    APPLY=1
fi

if [[ ! -f "$CSV" ]]; then
    echo "CSV not found: $CSV" >&2
    exit 1
fi
if ! command -v tag >/dev/null 2>&1; then
    echo "'tag' CLI not installed (brew install tag)" >&2
    exit 1
fi

# Files under this path are excluded — the Photos library manages its own
# copies and must not be touched.
EXCLUDE_RE="/Photos Library.photoslibrary/"

if [[ $APPLY -eq 1 ]]; then
    echo "== APPLY: rewriting tags under $ROOT =="
else
    echo "== DRY RUN: no changes. Re-run with --apply to write. =="
fi
echo "CSV:  $CSV"
echo "ROOT: $ROOT"
echo

total_files=0
total_pairs=0

# Read CSV, skipping the header line. Process substitution (not a pipe) so the
# running totals survive in this shell. bash 3.2 compatible — no mapfile.
while IFS=, read -r old new; do
    old="${old//$'\r'/}"; new="${new//$'\r'/}"
    [[ -z "$old" || -z "$new" ]] && continue

    # Exact multivalue match on the tag; scope to ROOT; drop Photos library.
    files=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        files+=("$f")
    done < <(mdfind -onlyin "$ROOT" "kMDItemUserTags == '$old'" 2>/dev/null | grep -v "$EXCLUDE_RE" || true)

    n=${#files[@]}
    printf '%-28s -> %-28s %4d file(s)\n' "$old" "$new" "$n"
    (( total_pairs++ )) || true
    (( total_files += n )) || true

    if [[ $APPLY -eq 1 && $n -gt 0 ]]; then
        for f in "${files[@]}"; do
            tag --remove "$old" "$f"
            tag --add    "$new" "$f"
        done
    fi
done < <(tail -n +2 "$CSV")

echo
echo "pairs processed: $total_pairs   tag-instances touched: $total_files"
if [[ $APPLY -eq 0 ]]; then
    echo "(dry run — nothing written)"
fi
