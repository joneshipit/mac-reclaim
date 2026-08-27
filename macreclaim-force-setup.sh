#!/bin/bash

# MacReclaim - Force Setup Assistant
# Run from Recovery when Step 3 left an empty login box instead of setup.
# Finds Data / Data 1 / Macintosh HD - Data (by name + Users/, not just dslocal),
# deletes leftover accounts, and unlocks + removes .AppleSetupDone.

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
	local b
	b=$(basename "$1")
	case "$b" in
		"macOS Base System"|"Preboot"|"Recovery"|"VM"|"Update"|"iSCPreboot"|"Hardware"|"xART"|"System"|".fseventsd")
			return 0
			;;
	esac
	return 1
}

score_data_volume() {
	local vol="$1"
	local score=0 n=0 u uname b

	[ -d "$vol/Users" ] && score=$((score + 50))
	[ -d "$vol/Users/Shared" ] && score=$((score + 10))
	[ -d "$vol/private/var/db/dslocal/nodes/Default/users" ] && score=$((score + 40))
	[ -d "$vol/var/db/dslocal/nodes/Default/users" ] && score=$((score + 40))
	[ -e "$vol/private/var/db/.AppleSetupDone" ] && score=$((score + 25))
	[ -e "$vol/var/db/.AppleSetupDone" ] && score=$((score + 25))
	[ -d "$vol/Library" ] && score=$((score + 10))
	[ -d "$vol/System/Library/CoreServices" ] && score=$((score - 15))

	b=$(basename "$vol")
	case "$b" in
		"Data 1"|"Data 2"|"Data"|"Macintosh HD - Data") score=$((score + 20)) ;;
	esac

	for u in \
		"$vol/private/var/db/dslocal/nodes/Default/users"/*.plist \
		"$vol/var/db/dslocal/nodes/Default/users"/*.plist
	do
		[ -f "$u" ] || continue
		uname=$(basename "$u" .plist)
		case "$uname" in
			_*|root|daemon|nobody|Guest) continue ;;
		esac
		n=$((n + 1))
	done
	score=$((score + ${n:-0} * 10))
	echo "$score"
}

find_data_volume() {
	local vol name best="" best_score=-1 score
	local tmp="/tmp/macreclaim-vols.$$"

	/bin/ls -1 /Volumes >"$tmp" 2>/dev/null

	printf "${BLU}  Volume probe:${NC}\n"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		vol="/Volumes/$name"
		[ -d "$vol" ] || continue
		if is_skipped_volume "$vol"; then
			printf "    %s  ${YEL}(skip)${NC}\n" "$name"
			continue
		fi
		score=$(score_data_volume "$vol")
		printf "    %s  users=%s  dslocal=%s  setup=%s  score=%s\n" \
			"$name" \
			"$([ -d "$vol/Users" ] && echo Y || echo n)" \
			"$([ -d "$vol/private/var/db/dslocal" ] || [ -d "$vol/var/db/dslocal" ] && echo Y || echo n)" \
			"$([ -e "$vol/private/var/db/.AppleSetupDone" ] || [ -e "$vol/var/db/.AppleSetupDone" ] && echo Y || echo n)" \
			"$score"
		if [ "$score" -gt "$best_score" ]; then
			best_score=$score
			best=$vol
		fi
	done <"$tmp"
	rm -f "$tmp"

	# Name fallback: Data 1 / Data / Macintosh HD - Data even if score is 0
	if [ -z "$best" ] || [ "$best_score" -le 0 ]; then
		for name in "Data 1" "Data 2" "Data" "Macintosh HD - Data"; do
			if [ -d "/Volumes/$name" ]; then
				best="/Volumes/$name"
				best_score=1
				printf "${YEL}  Falling back to volume name: ${best}${NC}\n"
				break
			fi
		done
	fi

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
	chmod u+w "$f" 2>/dev/null
	rm -f "$f"
}

printf "${YEL}[1] Mounting volumes...${NC}\n"
mount_macos_volumes
printf "${BLU}  Mounted volumes:${NC}\n"
/bin/ls -1 /Volumes 2>/dev/null | while IFS= read -r name; do
	printf "    %s\n" "$name"
done
printf "\n"

if ! find_data_volume; then
	printf "${RED}ERROR: Could not find a macOS Data volume.${NC}\n"
	printf "${YEL}  ls /Volumes:${NC}\n"
	/bin/ls -la /Volumes
	exit 1
fi
find_system_volume
printf "${GRN}  ✓ Data volume: ${DATA_VOL}${NC}\n"
printf "${GRN}  ✓ System volume: ${SYS_VOL}${NC}\n"
printf "\n"

printf "${YEL}[2] Deleting leftover accounts...${NC}\n"
deleted=0
for ds in \
	"$DATA_VOL/private/var/db/dslocal/nodes/Default/users" \
	"$DATA_VOL/var/db/dslocal/nodes/Default/users"
do
	[ -d "$ds" ] || continue
	for plist in "$ds"/*.plist; do
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
done
if [ $deleted -gt 0 ]; then
	printf "${GRN}  ✓ Deleted $deleted account(s)${NC}\n"
else
	printf "${BLU}  ℹ No leftover accounts${NC}\n"
fi
printf "\n"

printf "${YEL}[3] Unlocking and removing .AppleSetupDone on every volume...${NC}\n"
removed=0
# Direct paths first (spaces in Data 1)
for f in \
	"$DATA_VOL/private/var/db/.AppleSetupDone" \
	"$DATA_VOL/var/db/.AppleSetupDone" \
	"$DATA_VOL/private/var/db/.AppleDiagnosticsSetupDone" \
	"$DATA_VOL/var/db/.AppleDiagnosticsSetupDone" \
	"/Volumes/Data 1/private/var/db/.AppleSetupDone" \
	"/Volumes/Data 1/var/db/.AppleSetupDone" \
	"/Volumes/Data/private/var/db/.AppleSetupDone" \
	"/Volumes/Macintosh HD - Data/private/var/db/.AppleSetupDone" \
	"$SYS_VOL/var/db/.AppleSetupDone" \
	"$SYS_VOL/private/var/db/.AppleSetupDone"
do
	if [ -e "$f" ]; then
		printf "  removing %s\n" "$f"
		unlock_rm "$f"
		removed=$((removed + 1))
	fi
done

# Sweep in case it lives somewhere slightly different
find /Volumes -maxdepth 6 \( -name '.AppleSetupDone' -o -name '.AppleDiagnosticsSetupDone' \) 2>/dev/null | while IFS= read -r f; do
	[ -n "$f" ] || continue
	printf "  removing %s\n" "$f"
	unlock_rm "$f"
done

still=0
for f in \
	"$DATA_VOL/private/var/db/.AppleSetupDone" \
	"$DATA_VOL/var/db/.AppleSetupDone" \
	"/Volumes/Data 1/private/var/db/.AppleSetupDone"
do
	[ -e "$f" ] && still=$((still + 1))
done

if [ "$still" -gt 0 ]; then
	printf "${RED}  ✗ .AppleSetupDone still present${NC}\n"
	exit 1
fi
printf "${GRN}  ✓ .AppleSetupDone gone${NC}\n"
printf "\n"

printf "${GRN}Done. Close Terminal and restart — Setup Assistant should appear.${NC}\n"
printf "\n"
