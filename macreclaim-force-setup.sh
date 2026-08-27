#!/bin/bash

# MacReclaim - Unbrick empty login (Sonoma+)
# Setup Assistant will NOT relaunch on macOS 14+ once loginwindow is in
# charge, even with .AppleSetupDone gone and no users. This script creates
# an admin on the real APFS Data-role volume so you can log in.

RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

printf "\n"
printf "${CYAN}╔═══════════════════════════════════════════════════╗${NC}\n"
printf "${CYAN}║  MacReclaim - Create login admin (Sonoma+)        ║${NC}\n"
printf "${CYAN}╚═══════════════════════════════════════════════════╝${NC}\n"
printf "\n"
printf "${YEL}Setup Assistant will not come back on Sonoma. Creating a${NC}\n"
printf "${YEL}local admin so the empty login box has an account.${NC}\n"
printf "\n"

mount_all() {
	local ident
	for ident in $(diskutil list 2>/dev/null | sed -n 's/.*\(disk[0-9][0-9]*s[0-9][0-9]*\)$/\1/p'); do
		diskutil mount "$ident" 2>/dev/null
	done
}

# APFS volumes whose role is Data (the live user database at boot)
list_data_devs() {
	diskutil apfs list 2>/dev/null | awk '
		/APFS Volume Disk \(Role\):/ {
			line=$0
			# e.g. "APFS Volume Disk (Role):   disk3s5 (Data)"
			if (line ~ /\(Data\)/) {
				for (i=1; i<=NF; i++) {
					if ($i ~ /^disk[0-9]/) { print $i; break }
				}
			}
		}
	'
}

mount_point_of() {
	local dev="$1"
	local mp
	mp=$(diskutil info "$dev" 2>/dev/null | sed -n 's/^[[:space:]]*Mount Point:[[:space:]]*//p')
	if [ -z "$mp" ] || [ "$mp" = "Not Mounted" ]; then
		diskutil mount "$dev" >/dev/null 2>&1
		mp=$(diskutil info "$dev" 2>/dev/null | sed -n 's/^[[:space:]]*Mount Point:[[:space:]]*//p')
	fi
	if [ -n "$mp" ] && [ "$mp" != "Not Mounted" ]; then
		printf '%s\n' "$mp"
	fi
}

dscl_dir() {
	local root="$1"
	if [ -d "$root/private/var/db/dslocal/nodes/Default" ]; then
		printf '%s\n' "$root/private/var/db/dslocal/nodes/Default"
		return 0
	fi
	if [ -d "$root/var/db/dslocal/nodes/Default" ]; then
		printf '%s\n' "$root/var/db/dslocal/nodes/Default"
		return 0
	fi
	return 1
}

next_uid() {
	local users="$1/users"
	local uid=501
	while [ -n "$(grep -l "<integer>$uid</integer>" "$users"/*.plist 2>/dev/null)" ]; do
		uid=$((uid + 1))
		if [ "$uid" -gt 600 ]; then
			uid=501
			break
		fi
	done
	printf '%s\n' "$uid"
}

printf "${YEL}[1] Mounting APFS volumes...${NC}\n"
mount_all
printf "${BLU}  diskutil apfs list (roles):${NC}\n"
diskutil apfs list 2>/dev/null | grep -E 'Role\)|Name:|Mount Point:' | sed 's/^/   /'
printf "\n"

DATA_VOL=""
DSCL=""
best_score=-1
for dev in $(list_data_devs); do
	mp=$(mount_point_of "$dev")
	[ -n "$mp" ] || continue
	score=0
	[ -d "$mp/Users" ] && score=$((score + 50))
	ds=$(dscl_dir "$mp") && score=$((score + 80))
	printf "  Data-role %s -> %s  (score %s)\n" "$dev" "$mp" "$score"
	if [ "$score" -gt "$best_score" ]; then
		best_score=$score
		DATA_VOL=$mp
		DSCL=$ds
	fi
done

# Fallback: Data 1 / Data by name if role parse failed
if [ -z "$DATA_VOL" ]; then
	for name in "Data 1" "Data 2" "Data" "Macintosh HD - Data"; do
		if [ -d "/Volumes/$name" ]; then
			DATA_VOL="/Volumes/$name"
			DSCL=$(dscl_dir "$DATA_VOL")
			break
		fi
	done
fi

if [ -z "$DATA_VOL" ] || [ -z "$DSCL" ]; then
	printf "${RED}ERROR: no APFS Data volume with dslocal.${NC}\n"
	printf "  Tried Data-role devices and /Volumes/Data*.\n"
	/bin/ls -1 /Volumes
	exit 1
fi

printf "${GRN}  ✓ Using %s${NC}\n" "$DATA_VOL"
printf "${GRN}  ✓ dslocal %s${NC}\n" "$DSCL"
printf "\n"

printf "${YEL}[2] Remaining local users on this volume:${NC}\n"
users_dir="$DSCL/users"
found_human=0
if [ -d "$users_dir" ]; then
	for plist in "$users_dir"/*.plist; do
		[ -f "$plist" ] || continue
		u=$(basename "$plist" .plist)
		case "$u" in
			_*|root|daemon|nobody|Guest) printf "    %s  (system, skip)\n" "$u" ;;
			*)
				printf "    ${YEL}%s${NC}\n" "$u"
				found_human=1
				;;
		esac
	done
else
	printf "    ${RED}no users dir${NC}\n"
fi
printf "\n"

printf "${YEL}[3] Create a login admin${NC}\n"
printf "  Empty login box = type username + password (no user tiles).\n"
printf "  Username [reclaim]: "
read NEW_USER
[ -n "$NEW_USER" ] || NEW_USER="reclaim"
printf "  Password: "
read -s NEW_PASS
printf "\n"
if [ -z "$NEW_PASS" ]; then
	printf "${RED}Password cannot be empty.${NC}\n"
	exit 1
fi

if [ -f "$users_dir/$NEW_USER.plist" ]; then
	printf "${YEL}  Account %s already exists — resetting password.${NC}\n" "$NEW_USER"
	dscl -f "$DSCL" localhost -passwd "/Local/Default/Users/$NEW_USER" "$NEW_PASS" || {
		printf "${RED}  dscl passwd failed${NC}\n"
		exit 1
	}
	dscl -f "$DSCL" localhost -append "/Local/Default/Groups/admin" GroupMembership "$NEW_USER" 2>/dev/null
else
	uid=$(next_uid "$DSCL")
	printf "  Creating %s (uid %s) on %s\n" "$NEW_USER" "$uid" "$DATA_VOL"
	dscl -f "$DSCL" localhost -create "/Local/Default/Users/$NEW_USER" || {
		printf "${RED}  dscl create failed${NC}\n"
		exit 1
	}
	dscl -f "$DSCL" localhost -create "/Local/Default/Users/$NEW_USER" UserShell "/bin/zsh"
	dscl -f "$DSCL" localhost -create "/Local/Default/Users/$NEW_USER" RealName "$NEW_USER"
	dscl -f "$DSCL" localhost -create "/Local/Default/Users/$NEW_USER" UniqueID "$uid"
	dscl -f "$DSCL" localhost -create "/Local/Default/Users/$NEW_USER" PrimaryGroupID "20"
	mkdir -p "$DATA_VOL/Users/$NEW_USER"
	chmod 755 "$DATA_VOL/Users/$NEW_USER" 2>/dev/null
	dscl -f "$DSCL" localhost -create "/Local/Default/Users/$NEW_USER" NFSHomeDirectory "/Users/$NEW_USER"
	dscl -f "$DSCL" localhost -passwd "/Local/Default/Users/$NEW_USER" "$NEW_PASS" || {
		printf "${RED}  dscl passwd failed${NC}\n"
		exit 1
	}
	dscl -f "$DSCL" localhost -append "/Local/Default/Groups/admin" GroupMembership "$NEW_USER"
fi

# Don't hide the account; drop loginwindow "other user" quirks if possible
rm -f "$DATA_VOL/Library/Preferences/com.apple.loginwindow.plist" 2>/dev/null

if [ ! -f "$users_dir/$NEW_USER.plist" ]; then
	printf "${RED}  User plist was not created.${NC}\n"
	exit 1
fi

printf "\n"
printf "${GRN}╔═══════════════════════════════════════════════════╗${NC}\n"
printf "${GRN}║  Account ready                                    ║${NC}\n"
printf "${GRN}╚═══════════════════════════════════════════════════╝${NC}\n"
printf "\n"
printf "  Username: ${CYAN}%s${NC}\n" "$NEW_USER"
printf "  Volume:   %s\n" "$DATA_VOL"
printf "\n"
printf "${CYAN}Close Terminal and restart.${NC}\n"
printf "At the empty login box, type ${CYAN}%s${NC} and the password you just set.\n" "$NEW_USER"
printf "\n"
