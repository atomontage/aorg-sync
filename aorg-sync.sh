#!/usr/bin/env bash
#
# This script will synchronize an archive.org 'item' with a local directory.
# Only new files and files that have changed are downloaded. These checks take
# place based on file size, mtime and md5 hash.
#
# Requirements:
#
#   curl, jq, md5sum, GNU coreutils, GNU find, sed, pcregrep|GNU grep, awk
#
# This is free and unencumbered software released into the public domain.
# xristos@sdf.org

set -e

#
# Configuration
#

: "${BASE:=https://archive.org}"

# archive.org identifier for the item e.g.
# https://archive.org/details/[identifier]
: "${REMOTE:=0mhz-dos}"

# Change these to GNU (e.g. gstat, gtouch, gfind installed from macports) on macOS
# as the built-ins (BSD) do not support all features needed.
: "${STAT:=stat}"
: "${TOUCH:=touch}"
: "${FIND:=find}"

#
# End of user configuration
#

# Auto-set to pcregrep if found, otherwise use GNU grep as fallback.
mgrep="grep"
MGREP_ARGS=(-o)

CURL_ARGS=(--create-dirs -RSLf#)

index="${BASE}/download/${REMOTE}/${REMOTE}_files.xml"
index_md5=""

# HTTP metadata response (JSON)
md_json=""
# Multiline output: md5 size mtime name
md_parsed=""
# Multiline output: name
md_removed=""

# CLI options
do_index=1
do_prompt=1
do_force=0
do_delete=0
skip_mtime=1
force_mtime=1
check_cert=1

# Stats
new=0
updated=0
downloaded=0
deleted=0
failed=0
hashed=0

exitcode=0

function usage {
  echo "Usage: $0 [--force] [--delete] [--no-index] [--no-prompt] [--no-mtime] [--no-force-mtime] [--no-check-cert]"
  echo -e "  --force           force processing even if index hasn't changed"
  echo -e "                    ignored if --no-index is used"
  echo -e "  --delete          delete files that have been removed from the index"
  echo -e "                    WARN: This will delete all files present in the directory,"
  echo -e "                    that do not exist in the index"
  echo
  echo -e "  --no-index        do not download/process an index file (${REMOTE}_files.xml)"
  echo -e "  --no-prompt       do not prompt if index hasn't changed"
  echo -e "                    if --force, continue, otherwise exit"
  echo -e "  --no-mtime        do not check mtime to skip checking files whose size hasn't changed,"
  echo -e "                    hash every file"
  echo -e "  --no-force-mtime  do not auto-update mtime for every processed file"
  echo -e "  --no-check-cert   do not verify SSL certificates"
  echo
}

function fetch_metadata {
  printf '[-] Fetching %s\n' "${BASE}/metadata/${REMOTE}"
  if ! md_json="$(curl "${CURL_ARGS[@]}" "${BASE}/metadata/${REMOTE}")"; then
    return 1
  fi
  if ! md_parsed="$(jq -r '.files | .[] | "\(.md5) \(.size) \(.mtime) \(.name)"' \
                      <<< "$md_json")"; then
     return 1
  fi
  if ! index_md5="$(grep -E " ${REMOTE}_files.xml$" <<< "$md_parsed" | awk '{print $1}')"; then
    printf '[!] Missing %s_files.xml" in metadata JSON response\n' "${REMOTE}"
    return 1
  fi
}

function fetch_index {
  if [ "$do_index" -eq 0 ]; then
    return 0
  fi
  # Check local index if it exists
  if [ -e "${REMOTE}_files.xml" ]; then
    # We can't hash the file directly, but we can check whether the hash it contains
    # for ${REMOTE}_files.xml matches the hash we retrieved through the JSON API.
    local hash
    hash="$("$mgrep" "${MGREP_ARGS[@]}" "(?s)<file name=\"${REMOTE}_files.xml.*?</file>" ${REMOTE}_files.xml |
                 "$mgrep" "${MGREP_ARGS[@]}" '<md5>.*</md5>' |
                 sed -E 's/<\/?md5>//g' |
                 tr -d '\000')"
    if [ "$hash" = "$index_md5" ]; then
      if [ "$do_prompt" -eq 1 ]; then
        read -n1 -r -p "[-] No changes to index, continue (y/n)? " reply
        echo
        if [ "$reply" = "n" ]; then
          exit 0
        fi
      else
        if [ "$do_force" -eq 0 ]; then
          printf '[*] No changes to index\n'
          exit 0
        fi
        printf '[*] No changes to index, forcing update\n'
      fi
    else
      printf '[!] Index has changed -> %s\n' "$index_md5"
    fi
  else
    printf '[!] Local index does not exist\n'
  fi
  printf '[+] Downloading %s to %s\n' "$index" "${REMOTE}_files.xml"
  if ! curl "${CURL_ARGS[@]}" -o "${REMOTE}_files.xml" "$index"; then
   return 1
  fi
}

function check_hash {
  local file md5
  file="$1"
  md5="$2"

  if ! lmd5="$(md5sum "$file" | awk '{print $1}')"; then
    return 1
  fi
  if [ "$lmd5" != "$md5" ]; then
    return 1
  else
    return 0
  fi
}

function check_downloaded_file {
  local file md5 size lsize mtime
  file="$1"
  md5="$2"
  size="$3"
  mtime="$4"

  lsize="$(du -b "${file}.new" | awk '{print $1}')"
  if [ "$lsize" = "$size" ]; then
    # Check hash
    if ! check_hash "${file}.new" "$md5"; then
      exitcode=1
      ((failed++)) || true
      printf '[!!] MD5 FAIL\n'
    else
      mv "${file}.new" "$file"
      if [ "$force_mtime" -eq 1 ]; then
        # Curl should preserve mtime, but set it regardless if force_mtime is set
        "$TOUCH" --date="@$mtime" "$file"
      fi
    fi
  else
    exitcode=1
    ((failed++)) || true
    printf '[!!] size %s != %s\n' "$lsize" "$size"
  fi
  return 0
}

function download_file {
  local file encoded
  file="$1"
  if ! encoded="$(printf '%s' "$1" | jq -sRr @uri)"; then
    ((failed++)) || true
    return 1
  fi
  if curl "${CURL_ARGS[@]}" -o "${file}.new" "${BASE}/download/${REMOTE}/${encoded}"; then
    ((downloaded++)) || true
    return 0
  else
    ((failed++)) || true
    return 1
  fi
}

function diff_files {
  while read -r md5 size mtime file ; do
    if [ "$file" = "${REMOTE}_files.xml" ]; then
      # Skip the index as it's been previously processed
      continue
    fi
    if [ ! -f "$file" ]; then
      # Does not exist
      printf '[++] %s\n' "$file"
      download_file "$file" || continue
      check_downloaded_file "$file" "$md5" "$size" "$mtime"
      ((new++)) || true
    else
      local lsize
      lsize="$(du -b "$file" | awk '{print $1}')"
      if [ "$lsize" != "$size" ]; then
        # Exists but size differs
        printf '[+s] %s\n' "$file"
        download_file "$file" || continue
        check_downloaded_file "$file" "$md5" "$size" "$mtime"
        ((updated++)) || true
      else
        # Exists but size is identical
        if [ "$skip_mtime" -eq 1 ]; then
          # Skip processing if mtime is identical
          local lmtime
          lmtime="$("$STAT" -c %Y "$file")"
          if [ "$lmtime" = "$mtime" ]; then
            printf '[..] %s\n' "$file"
            continue
          fi
        fi
        printf '[==] %s\n' "$file"
        ((hashed++)) || true
        if ! check_hash "$file" "$md5"; then
          download_file "$file" || continue
          check_downloaded_file "$file" "$md5" "$size" "$mtime"
          ((updated++)) || true
        else
          # File is OK, force update mtime if set
          if [ "$force_mtime" -eq 1 ]; then
            "$TOUCH" --date="@$mtime" "$file"
          fi
        fi
      fi
    fi
  done <<< "$md_parsed"
  md_removed="$(comm -13 \
                  <(cut -d' ' -f4- <<< "$md_parsed" | sort) \
                  <("$FIND" . -type f -printf "%P\n" | grep -v "$(basename "$0")" | sort))"
  if [ -n "$md_removed" ]; then
    while read -r file ; do
      printf '[##] %s\n' "$file"
      if [ "$do_delete" -eq 1 ]; then
        rm -f "$file"
        ((deleted++)) || true
      fi
    done <<< "$md_removed"
  fi
  printf '[-]\n'
}

function print_stats {
  local total
  total="$(wc -l <<< "$md_parsed")"
  printf '[*] Total:\t %d\n' "$total"
  printf '[*] Downloaded:\t %d\n' "$downloaded"
  printf '[*] New:\t %d\n' "$new"
  printf '[*] Updated:\t %d\n' "$updated"
  printf '[*] Failed:\t %d\n' "$failed"
  printf '[*] Hashed:\t %d\n' "$hashed"
  printf '[*] Deleted:\t %d\n' "$deleted"
}

function interrupt {
  trap - INT
  echo
  print_stats
  exit 1
}


#
# Argument parsing
#


while :; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --force)
      do_force=1
      ;;
    --delete)
      do_delete=1
      ;;
    --no-index)
      do_index=0
      ;;
    --no-prompt)
      do_prompt=0
      ;;
    --no-mtime)
      skip_mtime=0
      ;;
    --no-force-mtime)
      force_mtime=0
      ;;
    --no-check-cert)
      check_cert=0
      ;;
    --)
      shift
      break
      ;;
    -?*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      break
  esac
  shift
done


#
# End of argument parsing
#

if [ "$check_cert" -eq 0 ]; then
  CURL_ARGS+=(-k)
fi

if type -P pcregrep >/dev/null; then
  mgrep="pcregrep"
  MGREP_ARGS+=(-M)
else
  MGREP_ARGS+=(-Pz)
fi

fetch_metadata
fetch_index

trap interrupt INT
diff_files
trap - INT

print_stats

if [ "$exitcode" -eq 0 ]; then
  exit 0
fi

exit 1
