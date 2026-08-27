#!/bin/bash

# MacReclaim — one shot, from Recovery.
# Auto-detects the APFS Data volume (Data, Data 1, Macintosh HD - Data,
# whatever Recovery named it), wipes local users, clears setup-done flags,
# blocks stale MDM, and boots the Hello / Setup Assistant on Sonoma 14.x.

RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

printf "\n"
printf "${CYAN}╔═══════════════════════════════════════════════════╗${NC}\n"
printf "${CYAN}║  MacReclaim — one shot                            ║${NC}\n"
printf "${CYAN}║  Detect volume → wipe users → Hello setup         ║${NC}\n"
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
			return 0 ;;
	esac
	return 1
}

list_devs_by_role() {
	local role="$1"
	diskutil apfs list 2>/dev/null | awk -v role="$role" '
		/APFS Volume Disk \(Role\):/ {
			if ($0 ~ "\\(" role "\\)") {
				for (i = 1; i <= NF; i++) {
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

add_root() {
	local p="$1"
	[ -d "$p" ] || return
	grep -qxF "$p" "$ROOTS" 2>/dev/null && return
	printf '%s\n' "$p" >>"$ROOTS"
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

block_mdm_hosts() {
	local hosts="$1"
	local domain
	[ -f "$hosts" ] || return 1
	for domain in \
		deviceenrollment.apple.com \
		mdmenrollment.apple.com \
		iprofiles.apple.com \
		acmdm.apple.com \
		axm-adm-mdm.apple.com \
		axm-adm-enroll.apple.com \
		albert.apple.com \
		identity.apple.com
	do
		if ! grep -qF "$domain" "$hosts" 2>/dev/null; then
			echo "0.0.0.0 $domain" >>"$hosts"
		fi
	done
}

# ── 1. Mount everything, detect Data + System ─────────
printf "${YEL}[1] Detecting disks...${NC}\n"

ROOTS=/tmp/macreclaim-roots.$$
: >"$ROOTS"

for ident in $(diskutil list 2>/dev/null | sed -n 's/.*\(disk[0-9][0-9]*s[0-9][0-9]*\)$/\1/p'); do
	diskutil mount "$ident" 2>/dev/null
done

printf "${BLU}  /Volumes:${NC}\n"
/bin/ls -1 /Volumes 2>/dev/null | while IFS= read -r name; do
	printf "    %s\n" "$name"
done

printf "${BLU}  APFS roles:${NC}\n"
diskutil apfs list 2>/dev/null | grep -E 'Role\)|Name:|Mount Point:' | sed 's/^/   /'

for dev in $(list_devs_by_role Data); do
	mp=$(mount_point_of "$dev")
	[ -n "$mp" ] || continue
	printf "${GRN}  ✓ Data-role %s -> %s${NC}\n" "$dev" "$mp"
	add_root "$mp"
	add_root "$mp/System/Volumes/Data"
done

for name in "Data 1" "Data 2" "Data" "Macintosh HD - Data" "Macintosh HD" "macOS"; do
	is_skipped_volname "$name" && continue
	add_root "/Volumes/$name"
	add_root "/Volumes/$name/System/Volumes/Data"
done

# Keep only roots that look like user-data (Users, dslocal, or var/db)
FILTERED=/tmp/macreclaim-filtered.$$
: >"$FILTERED"
while IFS= read -r root; do
	[ -d "$root" ] || continue
	if [ -d "$root/Users" ] || \
	   [ -d "$root/private/var/db/dslocal" ] || \
	   [ -d "$root/var/db/dslocal" ] || \
	   [ -d "$root/private/var/db" ]; then
		grep -qxF "$root" "$FILTERED" 2>/dev/null || printf '%s\n' "$root" >>"$FILTERED"
	fi
done <"$ROOTS"
mv "$FILTERED" "$ROOTS"

if [ ! -s "$ROOTS" ]; then
	printf "${RED}ERROR: no macOS Data volume found.${NC}\n"
	exit 1
fi

printf "${GRN}  Data roots I will use:${NC}\n"
while IFS= read -r root; do
	printf "    %s\n" "$root"
done <"$ROOTS"

SYS_VOL=""
for dev in $(list_devs_by_role System); do
	mp=$(mount_point_of "$dev")
	[ -d "$mp/System/Library/CoreServices" ] || continue
	case "$(basename "$mp")" in
		"macOS Base System") continue ;;
	esac
	SYS_VOL=$mp
	break
done
if [ -z "$SYS_VOL" ]; then
	for vol in "/Volumes/Macintosh HD" "/Volumes/macOS" /Volumes/*; do
		[ -d "$vol/System/Library/CoreServices" ] || continue
		case "$(basename "$vol")" in
			"macOS Base System") continue ;;
		esac
		SYS_VOL=$vol
		break
	done
fi

SYS_WRITABLE=false
if [ -n "$SYS_VOL" ]; then
	printf "${GRN}  ✓ System volume: %s${NC}\n" "$SYS_VOL"
	mount -uw "$SYS_VOL" 2>/dev/null
	if touch "$SYS_VOL/.rw_test" 2>/dev/null; then
		rm -f "$SYS_VOL/.rw_test"
		SYS_WRITABLE=true
		printf "${GRN}  ✓ System volume is writable${NC}\n"
	else
		printf "${YEL}  ⚠ System volume read-only (SIP/SSV). Data-volume work still runs — that is enough for Hello.${NC}\n"
	fi
else
	printf "${YEL}  ⚠ No system volume found — continuing on Data only${NC}\n"
fi
printf "\n"

# ── 2. Wipe local users (UID >= 500 blocks Hello on Sonoma) ──
printf "${YEL}[2] Deleting local users...${NC}\n"
deleted=0
while IFS= read -r root; do
	printf "${CYAN}  -- %s${NC}\n" "$root"
	for ds in \
		"$root/private/var/db/dslocal/nodes/Default/users" \
		"$root/var/db/dslocal/nodes/Default/users"
	do
		[ -d "$ds" ] || continue
		for plist in "$ds"/*.plist; do
			[ -f "$plist" ] || continue
			u=$(basename "$plist" .plist)
			uid=$(user_uid "$plist")
			if is_protected_user "$u"; then
				printf "    keep %s (uid %s)\n" "$u" "${uid:-?}"
				continue
			fi
			if [ -n "$uid" ] && [ "$uid" -lt 500 ] 2>/dev/null; then
				printf "    keep %s (system uid %s)\n" "$u" "$uid"
				continue
			fi
			printf "  ${YEL}Deleting %s (uid %s)${NC}\n" "$u" "${uid:-?}"
			force_rm "$plist"
			rm -rf "$root/Users/$u" 2>/dev/null
			deleted=$((deleted + 1))
		done
		rm -f "$ds"/*.bak "$ds"/*.plist.bak 2>/dev/null
	done
done <"$ROOTS"
printf "${GRN}  ✓ Removed %s local account(s)${NC}\n" "$deleted"
printf "\n"

# ── 3. Setup Assistant flags ──────────────────────────
printf "${YEL}[3] Forcing Hello / Setup Assistant...${NC}\n"
while IFS= read -r root; do
	printf "${CYAN}  -- %s${NC}\n" "$root"
	for f in \
		"$root/Library/Managed Preferences/com.apple.SetupAssistant.plist" \
		"$root/Library/Preferences/com.apple.SetupAssistant.plist" \
		"$root/Library/Preferences/com.apple.SetupAssistant.managed.plist" \
		"$root/Library/Preferences/com.apple.loginwindow.plist"
	do
		[ -e "$f" ] || continue
		printf "    rm %s\n" "$f"
		force_rm "$f"
	done
	write_skip_mdm_only "$root/Library/Managed Preferences"
	write_skip_mdm_only "$root/Library/Preferences"

	for db in "$root/private/var/db" "$root/var/db"; do
		mkdir -p "$db" 2>/dev/null
		for f in "$db/.AppleSetupDone" "$db/.AppleDiagnosticsSetupDone" "$db/.SetupRegComplete"; do
			if [ -e "$f" ] || [ -L "$f" ]; then
				printf "    rm %s\n" "$f"
				force_rm "$f" || printf "    ${RED}still there: %s${NC}\n" "$f"
			fi
		done
		touch "$db/.RunLanguageChooserToo" 2>/dev/null
		[ -f "$db/.RunLanguageChooserToo" ] && printf "    ${GRN}touched %s/.RunLanguageChooserToo${NC}\n" "$db"
	done
done <"$ROOTS"

find /Volumes -maxdepth 8 \( -name '.AppleSetupDone' -o -name '.AppleDiagnosticsSetupDone' \) 2>/dev/null | while IFS= read -r f; do
	[ -n "$f" ] || continue
	printf "    find-rm %s\n" "$f"
	force_rm "$f"
done
printf "\n"

# ── 4. Stale MDM data ─────────────────────────────────
printf "${YEL}[4] Clearing stale MDM enrollment data...${NC}\n"
nvram -d "com.apple.cloudconfig.activation-record" 2>/dev/null
nvram -d "enrollment-nonce" 2>/dev/null
nvram -d "com.apple.mdm.token" 2>/dev/null
nvram -d "com.apple.mdm.lock" 2>/dev/null

while IFS= read -r root; do
	profiles="$root/private/var/db/ConfigurationProfiles"
	[ -d "$root/private/var/db" ] || profiles="$root/var/db/ConfigurationProfiles"
	mkdir -p "$profiles/Settings" 2>/dev/null
	rm -f "$profiles/Settings/.cloudConfigHasActivationRecord" 2>/dev/null
	rm -f "$profiles/Settings/.cloudConfigRecordFound" 2>/dev/null
	rm -f "$profiles/Settings/.cloudConfigActivationRecord" 2>/dev/null
	touch "$profiles/Settings/.cloudConfigProfileInstalled" 2>/dev/null
	touch "$profiles/Settings/.cloudConfigRecordNotFound" 2>/dev/null
	rm -f "$root/private/var/db/SystemConfiguration/com.apple.wifi.known-networks.plist" 2>/dev/null
	rm -f "$root/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist" 2>/dev/null
done <"$ROOTS"
printf "${GRN}  ✓ Reclaim markers set${NC}\n"

if [ "$SYS_WRITABLE" = true ]; then
	block_mdm_hosts "$SYS_VOL/etc/hosts" && printf "${GRN}  ✓ MDM domains blocked in hosts${NC}\n"
	sys_profiles="$SYS_VOL/var/db/ConfigurationProfiles"
	mkdir -p "$sys_profiles/Settings" 2>/dev/null
	rm -f "$sys_profiles/Settings/.cloudConfigHasActivationRecord" 2>/dev/null
	rm -f "$sys_profiles/Settings/.cloudConfigRecordFound" 2>/dev/null
	rm -f "$sys_profiles/Settings/.cloudConfigActivationRecord" 2>/dev/null
	touch "$sys_profiles/Settings/.cloudConfigProfileInstalled" 2>/dev/null
	touch "$sys_profiles/Settings/.cloudConfigRecordNotFound" 2>/dev/null
	write_skip_mdm_only "$SYS_VOL/Library/Managed Preferences"

	for daemon in \
		com.apple.cloudconfigurationd.plist \
		com.apple.DeviceManagement.enrollmentd.plist \
		com.apple.ManagedClient.cloudconfigurationd.plist \
		com.apple.ManagedClient.enroll.plist \
		com.apple.ManagedClient.plist \
		com.apple.ManagedClient.startup.plist \
		com.apple.mdmclient.daemon.plist \
		com.apple.mdmclient.agent.plist \
		com.apple.mdmclient.plist
	do
		for dir in "$SYS_VOL/System/Library/LaunchDaemons" "$SYS_VOL/System/Library/LaunchAgents"; do
			[ -f "$dir/$daemon" ] || continue
			mv "$dir/$daemon" "$dir/${daemon}.disabled" 2>/dev/null && \
				printf "${GRN}  ✓ Disabled %s${NC}\n" "$daemon"
		done
	done

	if bless --mount "$SYS_VOL" --create-snapshot 2>/dev/null || \
	   bless --folder "$SYS_VOL/System/Library/CoreServices" --bootefi --create-snapshot 2>/dev/null; then
		printf "${GRN}  ✓ System snapshot blessed${NC}\n"
	fi
fi
printf "\n"

# ── 5. Verify ─────────────────────────────────────────
printf "${YEL}[5] Verify...${NC}\n"
fail=0
while IFS= read -r root; do
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
			printf "${RED}  leftover user %s on %s${NC}\n" "$u" "$root"
			fail=1
		done
	done
done <"$ROOTS"

left_done=$(find /Volumes -maxdepth 8 -name '.AppleSetupDone' 2>/dev/null)
if [ -n "$left_done" ]; then
	printf "${RED}  .AppleSetupDone still present:${NC}\n%s\n" "$left_done"
	fail=1
else
	printf "${GRN}  ✓ .AppleSetupDone gone${NC}\n"
fi

if find /Volumes -maxdepth 8 -name '.RunLanguageChooserToo' 2>/dev/null | grep -q .; then
	printf "${GRN}  ✓ .RunLanguageChooserToo in place${NC}\n"
else
	printf "${RED}  ✗ .RunLanguageChooserToo missing${NC}\n"
	fail=1
fi

rm -f "$ROOTS"

printf "\n"
if [ "$fail" -ne 0 ]; then
	printf "${RED}Not fully clean. Paste this output if Hello still does not appear.${NC}\n"
	exit 1
fi

printf "${GRN}╔═══════════════════════════════════════════════════╗${NC}\n"
printf "${GRN}║  Done. Close Terminal and restart.                ║${NC}\n"
printf "${GRN}║  Hello / Setup Assistant should appear.           ║${NC}\n"
printf "${GRN}╚═══════════════════════════════════════════════════╝${NC}\n"
printf "\n"
