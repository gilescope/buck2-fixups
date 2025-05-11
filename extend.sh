#!/usr/bin/env bash

[ $# -ne 2 ] && echo "Usage: $0 <source_dir> <target_dir>" && exit 1
[ ! -d "$1" ] && echo "Error: Source '$1' not found." && exit 1
[ ! -d "$2" ] && echo "Error: Target '$2' not found." && exit 1

for subdir in "$1"/*/; do
    name=$(basename "$subdir")
    [ ! -d "$2/$name" ] && cp -r "$subdir" "$2/" && echo "Copied: $name" || echo "Skipped: $name"
done
