#!/usr/bin/env bash
set -e -x

# Test:
reindeer buckify
buck2 build //...
