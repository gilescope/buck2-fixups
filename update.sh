#!/usr/bin/env bash

[ $# -ne 1 ] && echo "Usage: $0 <your_fixups_dir> - copy latest version of used fixups to your fixup dir" && exit 1
[ ! -d "$1" ] && echo "Error: Fixup target dir '$1' not found." && exit 1

for subdir in "$1"/*/; do
    name=$(basename "$subdir")
    if [ -d "$1/$name" ]; then
      cp -r "./fixups/$name"/* "$1/$name/"
      echo "Copied: $name"
    else
      echo "Skipped: $name"
    fi
done
