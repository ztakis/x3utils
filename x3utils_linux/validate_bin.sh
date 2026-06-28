#!/bin/bash
# validate_bin.sh — Shared .bin file validation
# Usage: source validate_bin.sh "$file_path"
# Output variables:
#   VALIDATE_RESULT  = OK | FAIL
#   VALIDATE_MSG     = Error description (if FAIL)
#   BIN_FILE_NAME    = Filename only
#   BIN_FILE_PATH    = Resolved absolute path

VALIDATE_RESULT="FAIL"
VALIDATE_MSG=""
BIN_FILE_NAME=""
BIN_FILE_PATH=""

_vbin_path="$1"

# 1. Check if path is empty
if [[ -z "$_vbin_path" ]]; then
    VALIDATE_MSG="No file provided."
    return 1 2>/dev/null || exit 1
fi

# 2. Resolve full path
_vbin_path="$(realpath "$_vbin_path" 2>/dev/null || echo "$_vbin_path")"

# 3. Check file exists
if [[ ! -f "$_vbin_path" ]]; then
    VALIDATE_MSG="File does not exist."
    return 1 2>/dev/null || exit 1
fi

# 4. Reject { or } in path
if [[ "$_vbin_path" =~ [{}] ]]; then
    VALIDATE_MSG="Path contains unsupported character: { or }. Please rename."
    return 1 2>/dev/null || exit 1
fi

# 5. Validate .bin extension
_vbin_ext="${_vbin_path##*.}"
if [[ "${_vbin_ext,,}" != "bin" ]]; then
    VALIDATE_MSG="Invalid file type .$_vbin_ext, only .bin is allowed."
    return 1 2>/dev/null || exit 1
fi

# 6. Validate exact size (128 KB = 131072 bytes)
_vbin_size=$(stat -c%s "$_vbin_path")
if [[ "$_vbin_size" != "131072" ]]; then
    VALIDATE_MSG="Invalid file size. Expected: 131072 bytes, Got: $_vbin_size bytes."
    return 1 2>/dev/null || exit 1
fi

# 7. Reject all-zero (single unique byte) content
_vbin_unique=$(od -An -tx1 "$_vbin_path" | tr -s ' \n' '\n' | grep -E '^[0-9a-f]{2}$' | sort -u | wc -l)
if [[ "$_vbin_unique" -eq 1 ]]; then
    VALIDATE_MSG="Bin file contains only a single repeated byte value."
    return 1 2>/dev/null || exit 1
fi

# All checks passed
BIN_FILE_NAME="$(basename "$_vbin_path")"
BIN_FILE_PATH="$_vbin_path"
VALIDATE_RESULT="OK"
VALIDATE_MSG=""
return 0 2>/dev/null || exit 0
