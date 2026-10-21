#!/usr/bin/env bash
# ===========================================================================
#  read-crash.sh -- read Unreal's own crash reports
#
#  UE4 writes a crash report folder under Saved/Crashes every time it dies,
#  even in a Shipping build where ordinary logging is compiled out. Inside is
#  CrashContext.runtime-xml, which carries the error message, the crash type
#  and the call stack -- the engine's own account of what went wrong, which
#  beats guessing from Wine's exit code.
#
#  Usage:  ./tools/read-crash.sh [--all] [--lines N]
#            --all      summarise every crash report, not just the newest
#            --lines N  call stack lines to print (default 30)
# ===========================================================================
set -uo pipefail

APP_ID="hello-neighbor"
APP_HOME="$HOME/.local/share/$APP_ID"
ALL=0
LINES=30

while [ $# -gt 0 ]; do
  case "$1" in
    --all)     ALL=1 ;;
    --lines)   shift; LINES="${1:-30}" ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ -t 1 ]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; C=""; N=""; fi

SAVED=""
for d in "$APP_HOME"/prefix/drive_c/users/*/AppData/Local/HelloNeighbor/Saved; do
  [ -d "$d" ] && { SAVED="$d"; break; }
done
[ -n "$SAVED" ] || { echo "No Saved folder found under the prefix." >&2; exit 1; }

CRASHES="$SAVED/Crashes"
[ -d "$CRASHES" ] || { echo "No Crashes folder -- the game has never recorded one." >&2; exit 1; }

section() { printf '\n%s===== %s =====%s\n' "$B$C" "$1" "$N"; }

# Print the contents of one XML tag. The report is often a single enormous
# line, so this strips everything before the open tag and after the close tag
# rather than assuming the value sits on its own line.
xml_block() { # xml_block <tag> <file>
  awk -v t="$1" '
    BEGIN { s = "<" t ">"; e = "</" t ">" }
    !inb && index($0, s) { inb = 1; sub(".*" s, "") }
    inb {
      if (index($0, e)) { sub(e ".*", ""); if (length($0)) print; exit }
      print
    }' "$2" 2>/dev/null
}

# --- inventory --------------------------------------------------------------
section "crash reports on disk"
mapfile -t DIRS < <(find "$CRASHES" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
                    | sort -rn | cut -d' ' -f2-)
if [ "${#DIRS[@]}" -eq 0 ]; then
  echo "none"; exit 0
fi
i=0
for d in "${DIRS[@]}"; do
  i=$((i+1))
  printf '  %s%-2s%s %s  %s\n' "$B" "$i" "$N" \
    "$(date -r "$d" '+%Y-%m-%d %H:%M' 2>/dev/null)" "$(basename "$d")"
done

# A crash report is only evidence about the run that produced it. The launch
# log filename carries the start time of the last run, so we can say plainly
# whether the newest report belongs to it -- otherwise it is far too easy to
# read an old report and "fix" a configuration that is no longer in use.
last_run_start() {
  local f base ts
  f="$(ls -t "$APP_HOME"/logs/launch-*.log 2>/dev/null | head -1)"
  [ -n "$f" ] || return 1
  base="$(basename "$f" .log)"; ts="${base#launch-}"
  date -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s 2>/dev/null
}
RUN_START="$(last_run_start || true)"
NEWEST_CRASH="$(date -r "${DIRS[0]}" +%s 2>/dev/null || echo 0)"
printf '\n'
if [ -n "$RUN_START" ] && [ "$NEWEST_CRASH" -lt "$RUN_START" ] 2>/dev/null; then
  printf '%sThe most recent run produced NO crash report.%s\n' "$R" "$N"
  printf 'Last run started %s; newest report is from %s.\n' \
    "$(date -d "@$RUN_START" '+%H:%M' 2>/dev/null)" \
    "$(date -d "@$NEWEST_CRASH" '+%H:%M' 2>/dev/null)"
  printf '\n%sThat is a finding, not a gap.%s Unreal writes a report from its own\n' "$Y" "$N"
  printf 'exception handler. If no report appears, the handler never ran, which\n'
  printf 'means the fault happened somewhere it could not reach -- typically in\n'
  printf 'Linux-side code called underneath Wine, such as the Vulkan driver.\n'
  printf 'Wine says as much when it prints "Exception frame is not in stack\n'
  printf 'limits => unable to dispatch exception".\n'
  printf '\n%sThe report below is from an OLDER run and may describe a%s\n' "$Y" "$N"
  printf '%sconfiguration you are no longer using.%s\n' "$Y" "$N"
else
  printf '%sNewest first. The top one is the run you just did.%s\n' "$G" "$N"
fi

show_one() { # show_one <dir>
  local d="$1" xml
  section "report $(basename "$d")  [$(date -r "$d" '+%Y-%m-%d %H:%M' 2>/dev/null)]"

  printf '%sfiles:%s %s\n\n' "$B" "$N" "$(ls "$d" 2>/dev/null | tr '\n' ' ')"

  xml="$d/CrashContext.runtime-xml"
  if [ -f "$xml" ]; then
    for tag in CrashType ErrorMessage GameName EngineVersion BuildVersion \
               PlatformFullName IsEnsure IsAssert CrashReporterMessage; do
      val="$(xml_block "$tag" "$xml" | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -4)"
      [ -n "$val" ] && printf '%s%-18s%s %s\n' "$G" "$tag:" "$N" "$val"
    done

    printf '\n%scall stack (first %s frames):%s\n' "$B" "$LINES" "$N"
    cs="$(xml_block CallStack "$xml" | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -"$LINES")"
    [ -n "$cs" ] || cs="$(xml_block PCallStack "$xml" | tr -d '\r' \
                          | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | head -"$LINES")"
    if [ -n "$cs" ]; then printf '%s\n' "$cs"
    else printf '%s(empty -- the engine could not unwind the stack)%s\n' "$Y" "$N"; fi
  else
    printf '%sno CrashContext.runtime-xml in this report%s\n' "$Y" "$N"
  fi

  # UE4 copies the game log into the crash folder, which is the one place a
  # Shipping build's log actually survives.
  for lg in "$d"/*.log "$d"/*.txt; do
    [ -f "$lg" ] || continue
    printf '\n%slast 25 lines of %s:%s\n' "$B" "$(basename "$lg")" "$N"
    tail -n 25 "$lg" 2>/dev/null | tr -d '\r'
  done
}

if [ "$ALL" = "1" ]; then
  for d in "${DIRS[@]}"; do show_one "$d"; done
else
  show_one "${DIRS[0]}"
fi

# --- the engine log, if one survived ---------------------------------------
section "Saved/Logs"
if [ -d "$SAVED/Logs" ] && [ -n "$(ls -A "$SAVED/Logs" 2>/dev/null)" ]; then
  newest="$(find "$SAVED/Logs" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  printf '%s  (%s)\n\n' "$(basename "$newest")" "$(date -r "$newest" '+%H:%M' 2>/dev/null)"
  printf '%slast 30 lines:%s\n' "$B" "$N"
  tail -n 30 "$newest" 2>/dev/null | tr -d '\r'
else
  printf 'empty -- this Shipping build has normal logging compiled out\n'
fi

printf '\n%sPaste the report section back to me -- the call stack is the useful part.%s\n\n' "$B" "$N"
