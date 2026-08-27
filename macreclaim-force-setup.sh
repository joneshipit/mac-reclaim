#!/bin/bash

# MacReclaim - Force Setup Assistant
# Run from Recovery when you get an empty login box instead of setup.
#
# Sonoma+ will NOT relaunch Setup Assistant if any local user still exists,
# even after deleting .AppleSetupDone. Also: Step 3 wrote DidSeeCloudSetup
# skip keys that can make Setup Assistant exit immediately to loginwindow.
#
# This script:
#   - operates on Data, Data 1, Macintosh HD - Data, AND System/Volumes/Data
#   - deletes leftover human accounts from every dslocal it finds
#   - chflags 0 + rm .AppleSetupDone (and diagnostics flag)
#   - removes SetupAssistant skip plists / loginwindow prefs
#   - touches .RunLanguageChooserToo so the first-run UI actually appears

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

printf "${BLU}  SIP: %s${NC}\n" "$(csrutil status 2>/dev/null | tr '\n' ' ')"
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

force_rm() {
	local f="$1"
	[ -e "$f" ] || [ -L "$f" ] || return 1
	chflags -R 0 "$f" 2>/dev/null
	xattr -c "$f" 2>/dev/null
	chmod -R u+w "$f" 2>/dev/null
	rm -rf "$f"
	[ -e "$f" ] && return 1
	return 0
}

collect_roots() {
	local tmp="$1"
	local name vol
	: >"$tmp"
	for name in "Data 1" "Data 2" "Data" "Macintosh HD - Data" "Macintosh HD" "macOS"; do
		vol="/Volumes/$name"
		[ -d "$vol" ] || continue
		if ! is_skipped_volume "$vol"; then
			grep -qxF "$vol" "$tmp" 2>/dev/null || printf '%s\n' "$vol" >>"$tmp"
		fi
		if [ -d "$vol/System/Volumes/Data" ]; then
			grep -qxF "$vol/System/Volumes/Data" "$tmp" 2>/dev/null || printf '%s\n' "$vol/System/Volumes/Data" >>"$tmp"
		fi
	done
	# any other /Volumes/* with Users
	local other
	for other in /Volumes/*; do
		[ -d "$other" ] || continue
		is_skipped_volume "$other" && continue
		if [ -d "$other/Users" ] || [ -d "$other/private/var/db" ]; then
			grep -qxF "$other" "$tmp" 2>/dev/null || printf '%s\n' "$other" >>"$tmp"
		fi
		if [ -d "$other/System/Volumes/Data" ]; then
			grep -qxF "$other/System/Volumes/Data" "$tmp" 2>/dev/null || printf '%s\n' "$other/System/Volumes/Data" >>"$tmp"
		fi
	done
}

delete_human_users() {
	local root="$1"
	local ds plist username deleted=0
	for ds in \
		"$root/private/var/db/dslocal/nodes/Default/users" \
		"$root/var/db/dslocal/nodes/Default/users"
	do
		[ -d "$ds" ] || continue
		printf "  dslocal: %s\n" "$ds"
		/bin/ls -1 "$ds" 2>/dev/null | sed 's/^/    /'
		for plist in "$ds"/*.plist; do
			[ -f "$plist" ] || continue
			username=$(basename "$plist" .plist)
			case "$username" in
				_*|root|daemon|nobody|Guest) continue ;;
			esac
			printf "  ${YEL}Deleting user: %s${NC}\n" "$username"
			force_rm "$plist"
			rm -rf "$root/Users/$username" 2>/dev/null
			deleted=$((deleted + 1))
		done
	done
	return 0
}

nuke_setup_flags() {
	local root="$1"
	local db f
	for db in "$root/private/var/db" "$root/var/db"; do
		mkdir -p "$db" 2>/dev/null
		for f in \
			"$db/.AppleSetupDone" \
			"$db/.AppleDiagnosticsSetupDone" \
			"$db/.SetupRegComplete" \
			"$db/.AppleSetupDone.bak"
		do
			if [ -e "$f" ] || [ -L "$f" ]; then
				printf "  ${YEL}rm %s${NC}\n" "$f"
				ls -lO "$f" 2>/dev/null
				if force_rm "$f"; then
					printf "  ${GRN}  gone${NC}\n"
				else
					printf "  ${RED}  STILL THERE${NC}\n"
				fi
			fi
		done
		# Force first-run UI even if macOS thinks language/setup already happened
		touch "$db/.RunLanguageChooserToo" 2>/dev/null
		if [ -f "$db/.RunLanguageChooserToo" ]; then
			printf "  ${GRN}touched %s/.RunLanguageChooserToo${NC}\n" "$db"
		fi
	done
}

nuke_skip_plists() {
	local root="$1"
	local f
	for f in \
		"$root/Library/Managed Preferences/com.apple.SetupAssistant.plist" \
		"$root/Library/Preferences/com.apple.SetupAssistant.plist" \
		"$root/Library/Preferences/com.apple.SetupAssistant.managed.plist" \
		"$root/Library/Preferences/com.apple.loginwindow.plist"
	do
		if [ -e "$f" ]; then
			printf "  ${YEL}rm %s${NC}\n" "$f"
			force_rm "$f"
		fi
	done
}

# ── run ──────────────────────────────────────────────
printf "${YEL}[1] Mounting volumes...${NC}\n"
mount_macos_volumes
printf "${BLU}  /Volumes:${NC}\n"
/bin/ls -1 /Volumes 2>/dev/null | while IFS= read -r name; do
	printf "    %s\n" "$name"
done
printf "\n"

ROOTS=/tmp/macreclaim-roots.$$
collect_roots "$ROOTS"
printf "${BLU}  Data roots I will touch:${NC}\n"
if [ ! -s "$ROOTS" ]; then
	printf "${RED}  none found${NC}\n"
	/bin/ls -la /Volumes
	exit 1
fi
while IFS= read -r root; do
	printf "    %s\n" "$root"
done <"$ROOTS"
printf "\n"

printf "${YEL}[2] Deleting leftover local users (Sonoma+ will not show Setup if any remain)...${NC}\n"
while IFS= read -r root; do
	printf "${CYAN}  -- %s${NC}\n" "$root"
	delete_human_users "$root"
done <"$ROOTS"
printf "\n"

printf "${YEL}[3] Removing .AppleSetupDone + writing .RunLanguageChooserToo...${NC}\n"
while IFS= read -r root; do
	printf "${CYAN}  -- %s${NC}\n" "$root"
	nuke_setup_flags "$root"
done <"$ROOTS"
# extra find sweep
find /Volumes -maxdepth 8 \( \
	-name '.AppleSetupDone' -o \
	-name '.AppleDiagnosticsSetupDone' -o \
	-name '.SetupRegComplete' \
\) 2>/dev/null | while IFS= read -r f; do
	[ -n "$f" ] || continue
	printf "  ${YEL}find-rm %s${NC}\n" "$f"
	force_rm "$f"
done
printf "\n"

printf "${YEL}[4] Removing Setup Assistant skip keys + loginwindow prefs...${NC}\n"
while IFS= read -r root; do
	printf "${CYAN}  -- %s${NC}\n" "$root"
	nuke_skip_plists "$root"
done <"$ROOTS"
printf "\n"

printf "${YEL}[5] Verify .AppleSetupDone is gone, .RunLanguageChooserToo exists...${NC}\n"
left=$(find /Volumes -maxdepth 8 -name '.AppleSetupDone' 2>/dev/null)
if [ -n "$left" ]; then
	printf "${RED}  STILL PRESENT:${NC}\n"
	printf "%s\n" "$left"
else
	printf "${GRN}  ✓ no .AppleSetupDone under /Volumes${NC}\n"
fi
find /Volumes -maxdepth 8 -name '.RunLanguageChooserToo' 2>/dev/null | while IFS= read -r f; do
	printf "  ${GRN}✓ %s${NC}\n" "$f"
done

rm -f "$ROOTS"

printf "\n"
printf "${GRN}Done. Close Terminal and restart.${NC}\n"
printf "${CYAN}You should get the language / Setup Assistant screen, not the login box.${NC}\n"
printf "\n"
