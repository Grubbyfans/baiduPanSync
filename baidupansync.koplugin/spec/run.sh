#!/usr/bin/env bash
# Runs this plugin's busted specs against a local KOReader checkout.
#
# Usage:
#   KOREADER_DIR=/path/to/koreader ./spec/run.sh [busted args...]
#
# The KOReader checkout must contain a built emulator (base/build/*/staging/bin/luajit).
# Test data and settings are written to a temporary KO_HOME and removed on exit;
# the KOReader checkout itself is never modified.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
KOREADER_DIR="${KOREADER_DIR:-$(cd "$PLUGIN_DIR/../.." && pwd -P)/koreader}"
KOREADER_DIR="$(cd "$KOREADER_DIR" && pwd -P)"

LUAJIT=""
for candidate in "$KOREADER_DIR"/base/build/*/staging/bin/luajit; do
    if [[ -x "$candidate" ]]; then
        LUAJIT="$candidate"
        break
    fi
done
if [[ -z "$LUAJIT" ]]; then
    echo "luajit not found under $KOREADER_DIR/base/build/*/staging/bin/" >&2
    echo "Build the KOReader emulator first (e.g. ./kodev build) or set KOREADER_DIR." >&2
    exit 1
fi
BUILD_DIR="$(cd "$(dirname "$(dirname "$(dirname "$LUAJIT")")")" && pwd -P)"

KO_HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bps-spec.XXXXXX")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bps-work.XXXXXX")"
cleanup() { rm -rf "$KO_HOME_DIR" "$WORK_DIR"; }
trap cleanup EXIT

# ReaderUI resolves some resources relative to the current directory (FontList
# uses "./fonts", luadefaults reads "defaults.lua"). Run from a scratch
# directory of symlinks instead of modifying the KOReader checkout.
ln -s "$KOREADER_DIR/resources" "$WORK_DIR/resources"
ln -s "$KOREADER_DIR/resources/fonts" "$WORK_DIR/fonts"
ln -s "$KOREADER_DIR/defaults.lua" "$WORK_DIR/defaults.lua"
ln -s "$KOREADER_DIR/frontend" "$WORK_DIR/frontend"

cd "$WORK_DIR"
# Pass the environment on the `env` command line: macOS SIP strips DYLD_* from
# exported variables before starting the interpreter, but honors assignments
# given directly to `env`.
exec env \
    KO_HOME="$KO_HOME_DIR" \
    BPS_PLUGIN_ROOT="$PLUGIN_DIR" \
    BPS_KOREADER_DIR="$KOREADER_DIR" \
    LUA_PATH="$PLUGIN_DIR/?.lua;$KOREADER_DIR/?.lua;$KOREADER_DIR/spec/unit/?.lua;$KOREADER_DIR/frontend/?.lua;$KOREADER_DIR/plugins/?.lua;$KOREADER_DIR/base/?.lua;$BUILD_DIR/common/?.lua;$BUILD_DIR/spec/rocks/share/lua/5.1/?.lua;$BUILD_DIR/spec/rocks/share/lua/5.1/?/init.lua;;" \
    LUA_CPATH="$BUILD_DIR/common/?.so;$BUILD_DIR/?.so;$BUILD_DIR/spec/rocks/lib/lua/5.1/?.so;;" \
    DYLD_LIBRARY_PATH="$BUILD_DIR/staging/lib:$BUILD_DIR/libs" \
    LD_LIBRARY_PATH="$BUILD_DIR/staging/lib:$BUILD_DIR/libs" \
    "$LUAJIT" -e 'require("ffi/loadlib"); require("busted.runner") {standalone = false}' \
    /dev/null --output=gtest --loaders=lua --lazy --no-keep-going "$PLUGIN_DIR/spec/unit" "$@"
