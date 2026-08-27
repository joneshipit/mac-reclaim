#!/bin/bash

# MacReclaim - Force Setup Assistant
# Run from Recovery when Step 3 left an empty login box instead of setup.
# Finds Data / Data 1 / Macintosh HD - Data, deletes leftover accounts,
# and unlocks + removes .AppleSetupDone (Step 1 sets uchg so a plain rm fails).

RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

printf "\n"
printf "${CYAN}╔═══════════════════════════════════════════════════╗${NC}\n"
printf "${CYAN}║  MacReclaim - Force Setup Assistant               ║${NC}\n"
printf "${CYAN}╚═══════════════════════════════════════════════════╝${NC}\n"
printf "\n"

mount_macos_volumes() {
	local ident
	diskutil mount "Macintosh HD" 2>/dev/null
	diskutil mount "Macintosh HD - Data" 2>/dev/null
	diskutil mount "Data" 2>/dev/null
	diskutil mount "Data 1" 2>/dev/null
	diskutil mount "Data 2" 2>/dev/null
	for ident in $(diskutil list 2>/dev/null | sed -n 's/.*\(disk[0-9]*s[0-9]*\)$/\1/p'); do
		diskutil mount "$ident" 2>/dev/null
	done
}

is_skipped_volume() {
	case "$1" in
		"/Volumes/macOS Base System"|"/Volumes/Preboot"|"/Volumes/Recovery"|"/Volumes/VM"|"/Volumes/Update"|"/Volumes/iSCPreboot"|"/Volumes/Hardware"|"/Volumes/xART"|"/Volumes/System")
			return 0
			;;
	esac
	return 1
}

find_data_volume() {
	local vol best="" best_score=-1 score n u uname

	for vol in /Volumes/*; do
		[ -d "$vol" ] || continue
		is_skipped_volume "$vol" && continue
		[ -d "$vol/System/Library/CoreServices" ] && continue
		[ -d "$vol/private/var/db/dslocal/nodes/Default/users" ] || continue

		score=10
		[ -d "$vol/Users" ] && score=$((score + 20))
		[ -d "$vol/Users/Shared" ] && score=$((score + 5))
		[ -f "$vol/private/var/db/.AppleSetupDone" ] && score=$((score + 15))
		n=0
		for u in "$vol/private/var/db/dslocal/nodes/Default/users"/*.plist; do
			[ -f "$u" ] || continue
			uname=$(basename "$u" .plist)
			case "$uname" in
				_*|root|daemon|nobody|Guest) continue ;;
			esac
			n=$((n + 1))
		done
		score=$((score + n * 10))
		if [ "$score" -gt "$best_score" ]; then
			best_score=$score
			best=$vol
		fi
	done

	if [ -n "$best" ]; then
		DATA_VOL=$best
		return 0
	fi
	return 1
}

find_system_volume() {
	local vol
	for vol in "/Volumes/Macintosh HD" "/Volumes/macOS" /Volumes/*; do
		[ -d "$vol/System/Library/CoreServices" ] || continue
		case "$(basename "$vol")" in
			"macOS Base System") continue ;;
		esac
		SYS_VOL=$vol
		return 0
	done
	SYS_VOL="/Volumes/Macintosh HD"
	return 1
}

unlock_rm() {
	local f="$1"
	[ -e "$f" ] || return 0
	chflags nouchg noschg nouappnd nosappnd "$f" 2>/dev/null
	rm -f "$f"
}

printf "${YEL}[1] Mounting volumes...${NC}\n"
mount_macos_volumes
printf "${BLU}  Mounted volumes:${NC}\n"
ls -1 /Volumes 2>/dev/null | while IFS= read -r name; do
	printf "    %s\n" "$name"
done

if ! find_data_volume; then
	printf "${RED}ERROR: Could not find a macOS Data volume.${NC}\n"
	exit 1
fi
find_system_volume
printf "${GRN}  ✓ Data volume: ${DATA_VOL}${NC}\n"
printf "${GRN}  ✓ System volume: ${SYS_VOL}${NC}\n"
printf "\n"

printf "${YEL}[2] Deleting leftover accounts...${NC}\n"
DSLOCAL="$DATA_VOL/private/var/db/dslocal/nodes/Default/users"
deleted=0
for plist in "$DSLOCAL"/*.plist; do
	[ -f "$plist" ] || continue
	username=$(basename "$plist" .plist)
	case "$username" in
		_*|root|daemon|nobody|Guest) continue ;;
	esac
	printf "  ${YEL}Deleting: $username${NC}\n"
	rm -f "$plist"
	rm -rf "$DATA_VOL/Users/$username" 2>/dev/null
	deleted=$((deleted + 1))
done
if [ $deleted -gt 0 ]; then
	printf "${GRN}  ✓ Deleted $deleted account(s)${NC}\n"
else
	printf "${BLU}  ℹ No leftover accounts${NC}\n"
fi
printf "\n"

printf "${YEL}[3] Unlocking and removing .AppleSetupDone...${NC}\n"
unlock_rm "$DATA_VOL/private/var/db/.AppleSetupDone"
unlock_rm "$DATA_VOL/private/var/db/.AppleDiagnosticsSetupDone"
unlock_rm "$SYS_VOL/var/db/.AppleSetupDone"
unlock_rm "$SYS_VOL/var/db/.AppleDiagnosticsSetupDone"
if [ -d "/Volumes/Data" ] && [ "$DATA_VOL" != "/Volumes/Data" ]; then
	unlock_rm "/Volumes/Data/private/var/db/.AppleSetupDone"
	unlock_rm "/Volumes/Data/private/var/db/.AppleDiagnosticsSetupDone"
fi

if [ -e "$DATA_VOL/private/var/db/.AppleSetupDone" ]; then
	printf "${RED}  ✗ Still present: ${DATA_VOL}/private/var/db/.AppleSetupDone${NC}\n"
	exit 1
fi
printf "${GRN}  ✓ .AppleSetupDone removed${NC}\n"
printf "\n"

printf "${GRN}Done. Close Terminal and restart — Setup Assistant should appear.${NC}\n"
printf "\n"
