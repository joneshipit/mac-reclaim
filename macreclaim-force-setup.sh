#!/bin/bash

# MacReclaim - Force Setup Assistant (Sonoma 14.x)
# Run from Recovery.
#
# Sonoma WILL show the Hello / Setup Assistant screen if:
#   1. No local users with UniqueID >= 500 remain
#   2. .AppleSetupDone is actually gone (step 1 locks it with uchg)
#   3. .RunLanguageChooserToo exists
#   4. DidSeeCloudSetup skip keys are not present (those dump you at loginwindow)
#
# Creating a login admin prevents Setup Assistant — this script does not do that.

RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

printf "\n"
printf "${CYAN}╔═══════════════════════════════════════════════════╗${NC}\n"
printf "${CYAN}║  MacReclaim - Force Setup Assistant (Sonoma)      ║${NC}\n"
printf "${CYAN}╚═══════════════════════════════════════════════════╝${NC}\n"
printf "\n"

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

is_skipped_volname() {
	case "$1" in
		"macOS Base System"|"Preboot"|"Recovery"|"VM"|"Update"|"iSCPreboot"|"Hardware"|"xART"|"System"|".fseventsd")
			return 0
			;;
	esac
	return 1
}

list_data_devs() {
	diskutil apfs list 2>/dev/null | awk '
		/APFS Volume Disk \(Role\):/ {
			if ($0 ~ /\(Data\)/) {
				for (i=1; i<=NF; i++) {
					if ($i ~ /^disk[0-9]/) { print $i; break }
				}
			}
		}
	'
}

mount_point_of() {
	local dev="$1" mp
	mp=$(diskutil info "$dev" 2>/dev/null | sed -n 's/^[[:space:]]*Mount Point:[[:space:]]*//p')
	if [ -z "$mp" ] || [ "$mp" = "Not Mounted" ]; then
		diskutil mount "$dev" >/dev/null 2>&1
		mp=$(diskutil info "$dev" 2>/dev/null | sed -n 's/^[[:space:]]*Mount Point:[[:space:]]*//p')
	fi
	if [ -n "$mp" ] && [ "$mp" != "Not Mounted" ]; then
		printf '%s\n' "$mp"
	fi
}

collect_roots() {
	local tmp="$1" name vol mp dev
	: >"$tmp"
	add() {
		local p="$1"
		[ -d "$p" ] || return
		grep -qxF "$p" "$tmp" 2>/dev/null && return
		printf '%s\n' "$p" >>"$tmp"
	}

	for ident in $(diskutil list 2>/dev/null | sed -n 's/.*\(disk[0-9][0-9]*s[0-9][0-9]*\)$/\1/p'); do
		diskutil mount "$ident" 2>/dev/null
	done

	for dev in $(list_data_devs); do
		mp=$(mount_point_of "$dev")
		add "$mp"
		add "$mp/System/Volumes/Data"
	done

	for name in "Data 1" "Data 2" "Data" "Macintosh HD - Data" "Macintosh HD" "macOS"; do
		vol="/Volumes/$name"
		is_skipped_volname "$name" && continue
		add "$vol"
		add "$vol/System/Volumes/Data"
	done
}

user_uid() {
	local plist="$1" uid
	uid=$(/usr/libexec/PlistBuddy -c 'Print :UniqueID:0' "$plist" 2>/dev/null)
	[ -n "$uid" ] || uid=$(/usr/libexec/PlistBuddy -c 'Print :UniqueID' "$plist" 2>/dev/null)
	printf '%s' "$uid" | tr -dc '0-9-'
}

is_protected_user() {
	case "$1" in
		root|daemon|nobody|Guest) return 0 ;;
	esac
	return 1
}

delete_local_users() {
	local root="$1"
	local ds plist u uid
	local deleted=0
	for ds in \
		"$root/private/var/db/dslocal/nodes/Default/users" \
		"$root/var/db/dslocal/nodes/Default/users"
	do
		[ -d "$ds" ] || continue
		printf "  dslocal %s\n" "$ds"
		for plist in "$ds"/*.plist; do
			[ -f "$plist" ] || continue
			u=$(basename "$plist" .plist)
			uid=$(user_uid "$plist")
			if is_protected_user "$u"; then
				printf "    keep %s (uid %s)\n" "$u" "${uid:-?}"
				continue
			fi
			# Sonoma treats UniqueID >= 500 as a local user that blocks Setup Assistant.
			# Also drop named human accounts even if UniqueID cannot be read.
			if [ -n "$uid" ] && [ "$uid" -lt 500 ] 2>/dev/null; then
				printf "    keep %s (system uid %s)\n" "$u" "$uid"
				continue
			fi
			printf "  ${YEL}Deleting %s (uid %s)${NC}\n" "$u" "${uid:-?}"
			force_rm "$plist"
			rm -rf "$root/Users/$u" 2>/dev/null
			deleted=$((deleted + 1))
		done
		# leftover backups from other tools
		rm -f "$ds"/*.bak "$ds"/*.plist.bak 2>/dev/null
	done
	return 0
}

remaining_local_users() {
	local root="$1"
	local ds plist u uid
	for ds in \
		"$root/private/var/db/dslocal/nodes/Default/users" \
		"$root/var/db/dslocal/nodes/Default/users"
	do
		[ -d "$ds" ] || continue
		for plist in "$ds"/*.plist; do
			[ -f "$plist" ] || continue
			u=$(basename "$plist" .plist)
			is_protected_user "$u" && continue
			uid=$(user_uid "$plist")
			if [ -n "$uid" ] && [ "$uid" -lt 500 ] 2>/dev/null; then
				continue
			fi
			printf '%s\n' "$u"
		done
	done
}

write_skip_mdm_only() {
	local dir="$1"
	mkdir -p "$dir" 2>/dev/null
	cat > "$dir/com.apple.SetupAssistant.plist" << 'SKIPEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SkipDeviceManagement</key>
	<true/>
</dict>
</plist>
SKIPEOF
}

nuke_setup_state() {
	local root="$1"
	local db f

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
	# MDM pane only — do not set DidSeeCloudSetup (that skips Hello / create account)
	write_skip_mdm_only "$root/Library/Managed Preferences"
	write_skip_mdm_only "$root/Library/Preferences"

	for db in "$root/private/var/db" "$root/var/db"; do
		mkdir -p "$db" 2>/dev/null
		for f in \
			"$db/.AppleSetupDone" \
			"$db/.AppleDiagnosticsSetupDone" \
			"$db/.SetupRegComplete"
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
		touch "$db/.RunLanguageChooserToo" 2>/dev/null
		if [ -f "$db/.RunLanguageChooserToo" ]; then
			printf "  ${GRN}touched %s/.RunLanguageChooserToo${NC}\n" "$db"
		fi
	done
}

# ── run ──────────────────────────────────────────────
printf "${YEL}[1] Mounting volumes...${NC}\n"
ROOTS=/tmp/macreclaim-roots.$$
collect_roots "$ROOTS"
printf "${BLU}  Data roots:${NC}\n"
if [ ! -s "$ROOTS" ]; then
	printf "${RED}  none found${NC}\n"
	/bin/ls -1 /Volumes
	exit 1
fi
while IFS= read -r root; do
	printf "    %s\n" "$root"
done <"$ROOTS"
printf "\n"

printf "${YEL}[2] Deleting local users (UID >= 500 blocks Setup Assistant on Sonoma)...${NC}\n"
while IFS= read -r root; do
	printf "${CYAN}  -- %s${NC}\n" "$root"
	delete_local_users "$root"
done <"$ROOTS"
printf "\n"

printf "${YEL}[3] Clearing setup-done flags + skip keys...${NC}\n"
while IFS= read -r root; do
	printf "${CYAN}  -- %s${NC}\n" "$root"
	nuke_setup_state "$root"
done <"$ROOTS"
find /Volumes -maxdepth 8 \( -name '.AppleSetupDone' -o -name '.AppleDiagnosticsSetupDone' \) 2>/dev/null | while IFS= read -r f; do
	[ -n "$f" ] || continue
	printf "  ${YEL}find-rm %s${NC}\n" "$f"
	force_rm "$f"
done
printf "\n"

printf "${YEL}[4] Verify...${NC}\n"
left_users=""
while IFS= read -r root; do
	u=$(remaining_local_users "$root")
	if [ -n "$u" ]; then
		printf "${RED}  local users still on %s:${NC}\n" "$root"
		printf '%s\n' "$u" | sed 's/^/    /'
		left_users=1
	fi
done <"$ROOTS"

left_done=$(find /Volumes -maxdepth 8 -name '.AppleSetupDone' 2>/dev/null)
if [ -n "$left_done" ]; then
	printf "${RED}  .AppleSetupDone still present:${NC}\n"
	printf '%s\n' "$left_done"
fi

chooser=$(find /Volumes -maxdepth 8 -name '.RunLanguageChooserToo' 2>/dev/null)
if [ -n "$chooser" ]; then
	printf "${GRN}  ✓ .RunLanguageChooserToo:${NC}\n"
	printf '%s\n' "$chooser" | sed 's/^/    /'
else
	printf "${RED}  ✗ .RunLanguageChooserToo was not created${NC}\n"
fi

rm -f "$ROOTS"

if [ -n "$left_users" ] || [ -n "$left_done" ]; then
	printf "\n${RED}Not clean yet — Setup Assistant may still skip to login.${NC}\n"
	exit 1
fi

printf "\n"
printf "${GRN}Clean. Close Terminal and restart.${NC}\n"
printf "${CYAN}You should get Hello / language / create-account — not the login box.${NC}\n"
printf "\n"
