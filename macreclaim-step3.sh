#!/bin/bash

# MacReclaim - Enterprise Mac Recovery (Step 3 of 3)
# Run from Recovery Mode AFTER Step 2.
# Final cleanup: removes stale enrollment data, deletes temp
# accounts, and prepares a clean Setup Assistant experience.
# Multi-pronged approach with SSV (Signed System Volume) unlock.

RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

printf "\n"
printf "${CYAN}╔═══════════════════════════════════════════════════╗${NC}\n"
printf "${CYAN}║  MacReclaim - Enterprise Mac Recovery (Step 3)   ║${NC}\n"
printf "${CYAN}║  Preventing e-waste by reclaiming MacBooks       ║${NC}\n"
printf "${CYAN}╚═══════════════════════════════════════════════════╝${NC}\n"
printf "\n"

# ═══════════════════════════════════════════════════════
# Helpers: volume detection (Data / Data 1 / Macintosh HD - Data)
# Never rename volumes — a rename collision is what creates "Data 1".
# ═══════════════════════════════════════════════════════
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
	score=$((score + n * 10))
	echo "$score"
}

# Pick Data / Data 1 / Macintosh HD - Data by Users/ + name.
# Do not require dslocal (Recovery often mounts it without that path).
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
	return 1
}

unlock_rm() {
	local f="$1"
	[ -e "$f" ] || [ -L "$f" ] || return 0
	chflags -R 0 "$f" 2>/dev/null
	xattr -c "$f" 2>/dev/null
	chmod -R u+w "$f" 2>/dev/null
	rm -rf "$f"
}

# ═══════════════════════════════════════════════════════
# PHASE 0: Mount and prepare volumes
# ═══════════════════════════════════════════════════════
printf "${YEL}[0] Mounting volumes...${NC}\n"

mount_macos_volumes

printf "${BLU}  Mounted volumes:${NC}\n"
ls -1 /Volumes 2>/dev/null | while IFS= read -r name; do
	printf "    %s\n" "$name"
done

if ! find_data_volume; then
	printf "${RED}ERROR: Could not find a macOS Data volume (looked for Data, Data 1, Macintosh HD - Data).${NC}\n"
	exit 1
fi
printf "${GRN}  ✓ Data volume: ${DATA_VOL}${NC}\n"

if find_system_volume; then
	printf "${GRN}  ✓ System volume: ${SYS_VOL}${NC}\n"
	SYS_AVAILABLE=true
else
	printf "${YEL}  ⚠ System volume not mounted${NC}\n"
	SYS_VOL="/Volumes/Macintosh HD"
	SYS_AVAILABLE=false
fi
printf "\n"

# ═══════════════════════════════════════════════════════
# PHASE 1: Check SIP status + mount system volume
# ═══════════════════════════════════════════════════════
printf "${YEL}[1] Checking system volume protection...${NC}\n"

sip_status=$(csrutil status 2>/dev/null)
if echo "$sip_status" | grep -q "disabled"; then
	printf "${GRN}  ✓ SIP is disabled${NC}\n"
else
	printf "${RED}  ✗ SIP is still enabled${NC}\n"
	printf "\n"
	printf "${CYAN}  Run these commands first, then re-run this script:${NC}\n"
	printf "    ${GRN}csrutil disable${NC}\n"
	printf "    ${GRN}csrutil authenticated-root disable${NC}\n"
	printf "\n"
	printf "${YEL}  When prompted — Username: ${GRN}<admin_user>${YEL}  Password: ${GRN}<password>${NC}\n"
	printf "\n"
	printf "  Continue anyway without system volume access? (y/n): "
	read -r skip_sip
	if [ "$skip_sip" != "y" ] && [ "$skip_sip" != "Y" ]; then
		printf "Exiting. Disable SIP and run this script again.\n"
		exit 0
	fi
fi

if [ "$SYS_AVAILABLE" = true ]; then
	mount -uw "$SYS_VOL" 2>/dev/null
	if touch "$SYS_VOL/.rw_test" 2>/dev/null; then
		rm -f "$SYS_VOL/.rw_test"
		printf "${GRN}  ✓ System volume mounted read-write${NC}\n"
		SYS_WRITABLE=true
	else
		printf "${YEL}  ⚠ System volume is read-only — system attacks will be skipped${NC}\n"
		SYS_WRITABLE=false
	fi
else
	SYS_WRITABLE=false
fi
printf "\n"

# ═══════════════════════════════════════════════════════
# ATTACK 1: Clear NVRAM
# On Intel/T2 Macs, stale DEP record may live in NVRAM.
# On Apple Silicon, this clears user NVRAM vars but
# won't touch the SEP-stored activation record.
# ═══════════════════════════════════════════════════════
printf "${YEL}[2] Clearing stale MDM-related NVRAM keys...${NC}\n"
nvram -d "com.apple.cloudconfig.activation-record" 2>/dev/null
nvram -d "enrollment-nonce" 2>/dev/null
nvram -d "com.apple.mdm.token" 2>/dev/null
nvram -d "com.apple.mdm.lock" 2>/dev/null
printf "${GRN}  ✓ Stale MDM NVRAM keys cleared${NC}\n"
printf "\n"

# ═══════════════════════════════════════════════════════
# ATTACK 2: Nuke ALL stale MDM/enrollment data
# ═══════════════════════════════════════════════════════
printf "${YEL}[3] Removing stale MDM enrollment data...${NC}\n"

data_profiles="$DATA_VOL/private/var/db/ConfigurationProfiles"
if [ -d "$data_profiles" ]; then
	rm -f "$data_profiles/Settings/.cloudConfigHasActivationRecord" 2>/dev/null
	rm -f "$data_profiles/Settings/.cloudConfigRecordFound" 2>/dev/null
	rm -f "$data_profiles/Settings/.cloudConfigActivationRecord" 2>/dev/null
	for f in "$data_profiles/Store"/*.enrollment* "$data_profiles/Store"/*mdm* "$data_profiles/Store"/*MDM*; do
		[ -e "$f" ] && rm -f "$f"
	done
	for f in "$data_profiles"/*.enrollment*; do
		[ -e "$f" ] && rm -f "$f"
	done
fi
mkdir -p "$data_profiles/Settings" 2>/dev/null
touch "$data_profiles/Settings/.cloudConfigProfileInstalled" 2>/dev/null
touch "$data_profiles/Settings/.cloudConfigRecordNotFound" 2>/dev/null
printf "${GRN}  ✓ Data volume: stale MDM data removed, reclaim markers set${NC}\n"

if [ "$SYS_WRITABLE" = true ]; then
	sys_profiles="$SYS_VOL/var/db/ConfigurationProfiles"
	if [ -d "$sys_profiles" ]; then
		rm -f "$sys_profiles/Settings/.cloudConfigHasActivationRecord" 2>/dev/null
		rm -f "$sys_profiles/Settings/.cloudConfigRecordFound" 2>/dev/null
		rm -f "$sys_profiles/Settings/.cloudConfigActivationRecord" 2>/dev/null
		mkdir -p "$sys_profiles/Settings" 2>/dev/null
		touch "$sys_profiles/Settings/.cloudConfigProfileInstalled" 2>/dev/null
		touch "$sys_profiles/Settings/.cloudConfigRecordNotFound" 2>/dev/null
		printf "${GRN}  ✓ System volume: reclaim markers set${NC}\n"
	fi
fi
printf "\n"

# ═══════════════════════════════════════════════════════
# ATTACK 3: Disable orphaned MDM enrollment daemons
# Rename daemon plists so launchd doesn't load them.
# Requires writable system volume (SSV disabled).
# ═══════════════════════════════════════════════════════
printf "${YEL}[4] Disabling orphaned MDM enrollment daemons...${NC}\n"

if [ "$SYS_WRITABLE" = true ]; then
	mdm_daemons=(
		"com.apple.cloudconfigurationd.plist"
		"com.apple.DeviceManagement.enrollmentd.plist"
		"com.apple.ManagedClient.cloudconfigurationd.plist"
		"com.apple.ManagedClient.enroll.plist"
		"com.apple.ManagedClient.plist"
		"com.apple.ManagedClient.startup.plist"
		"com.apple.mdmclient.daemon.plist"
		"com.apple.mdmclient.agent.plist"
		"com.apple.mdmclient.plist"
	)

	disabled_count=0
	for daemon in "${mdm_daemons[@]}"; do
		for dir in "$SYS_VOL/System/Library/LaunchDaemons" "$SYS_VOL/System/Library/LaunchAgents"; do
			if [ -f "$dir/$daemon" ]; then
				mv "$dir/$daemon" "$dir/${daemon}.disabled" 2>/dev/null
				if [ $? -eq 0 ]; then
					printf "${GRN}  ✓ Disabled: $daemon${NC}\n"
					disabled_count=$((disabled_count + 1))
				fi
			fi
		done
	done

	if [ $disabled_count -eq 0 ]; then
		printf "${YEL}  ⚠ No daemons found to disable (names may differ on Tahoe)${NC}\n"
	fi
else
	printf "${YEL}  ⚠ Skipped — system volume is read-only${NC}\n"
	printf "${BLU}  To fix: reboot into Recovery, run this script again.${NC}\n"
	printf "${BLU}  SIP disable may need a reboot to take effect.${NC}\n"
fi
printf "\n"

# ═══════════════════════════════════════════════════════
# ATTACK 4: Managed preferences skip keys
# ═══════════════════════════════════════════════════════
printf "${YEL}[5] Writing Setup Assistant skip keys...${NC}\n"

managed_dir="$DATA_VOL/Library/Managed Preferences"
mkdir -p "$managed_dir" 2>/dev/null

cat > "$managed_dir/com.apple.SetupAssistant.plist" << 'SKIPEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SkipDeviceManagement</key>
	<true/>
</dict>
</plist>
SKIPEOF
printf "${GRN}  ✓ Skip keys written to Managed Preferences${NC}\n"

data_prefs="$DATA_VOL/Library/Preferences"
mkdir -p "$data_prefs" 2>/dev/null
cp "$managed_dir/com.apple.SetupAssistant.plist" "$data_prefs/com.apple.SetupAssistant.plist" 2>/dev/null

if [ "$SYS_WRITABLE" = true ]; then
	sys_managed="$SYS_VOL/Library/Managed Preferences"
	mkdir -p "$sys_managed" 2>/dev/null
	cp "$managed_dir/com.apple.SetupAssistant.plist" "$sys_managed/" 2>/dev/null
	printf "${GRN}  ✓ Skip keys written to system volume${NC}\n"
fi
printf "\n"

# ═══════════════════════════════════════════════════════
# ATTACK 5: Clear WiFi networks
# ═══════════════════════════════════════════════════════
printf "${YEL}[6] Clearing saved WiFi networks...${NC}\n"

rm -f "$DATA_VOL/private/var/db/SystemConfiguration/com.apple.wifi.known-networks.plist" 2>/dev/null
rm -f "$DATA_VOL/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist" 2>/dev/null
rm -f "$DATA_VOL/Library/Preferences/SystemConfiguration/com.apple.wifi.message-tracer.plist" 2>/dev/null
printf "${GRN}  ✓ WiFi networks cleared${NC}\n"
printf "\n"

# ═══════════════════════════════════════════════════════
# CLEANUP: Delete all users & remove .AppleSetupDone
# Step 1 locks .AppleSetupDone with uchg — rm -f is a no-op until unlocked.
# ═══════════════════════════════════════════════════════
printf "${YEL}[7] Deleting local accounts (UID >= 500 blocks Setup Assistant on Sonoma)...${NC}\n"

user_uid() {
	local plist="$1" uid
	uid=$(/usr/libexec/PlistBuddy -c 'Print :UniqueID:0' "$plist" 2>/dev/null)
	[ -n "$uid" ] || uid=$(/usr/libexec/PlistBuddy -c 'Print :UniqueID' "$plist" 2>/dev/null)
	printf '%s' "$uid" | tr -dc '0-9-'
}

deleted=0
for root in "$DATA_VOL" "/Volumes/Data 1" "/Volumes/Data" "/Volumes/Macintosh HD - Data" "$SYS_VOL/System/Volumes/Data"; do
	[ -d "$root" ] || continue
	for DSLOCAL in \
		"$root/private/var/db/dslocal/nodes/Default/users" \
		"$root/var/db/dslocal/nodes/Default/users"
	do
		[ -d "$DSLOCAL" ] || continue
		for plist in "$DSLOCAL"/*.plist; do
			[ -f "$plist" ] || continue
			username=$(basename "$plist" .plist)
			case "$username" in
				root|daemon|nobody|Guest) continue ;;
			esac
			uid=$(user_uid "$plist")
			if [ -n "$uid" ] && [ "$uid" -lt 500 ] 2>/dev/null; then
				continue
			fi
			printf "  ${YEL}Deleting: %s (uid %s) on %s${NC}\n" "$username" "${uid:-?}" "$root"
			unlock_rm "$plist"
			rm -rf "$root/Users/$username" 2>/dev/null
			deleted=$((deleted + 1))
		done
	done
done

if [ $deleted -gt 0 ]; then
	printf "${GRN}  ✓ Deleted $deleted account(s)${NC}\n"
else
	printf "${BLU}  ℹ No accounts to delete${NC}\n"
fi

printf "${YEL}[7b] Unlocking and removing .AppleSetupDone...${NC}\n"
for f in \
	"$DATA_VOL/private/var/db/.AppleSetupDone" \
	"$DATA_VOL/var/db/.AppleSetupDone" \
	"$DATA_VOL/private/var/db/.AppleDiagnosticsSetupDone" \
	"$DATA_VOL/var/db/.AppleDiagnosticsSetupDone" \
	"/Volumes/Data 1/private/var/db/.AppleSetupDone" \
	"/Volumes/Data/private/var/db/.AppleSetupDone" \
	"/Volumes/Macintosh HD - Data/private/var/db/.AppleSetupDone" \
	"$SYS_VOL/var/db/.AppleSetupDone" \
	"$SYS_VOL/var/db/.AppleDiagnosticsSetupDone" \
	"$SYS_VOL/System/Volumes/Data/private/var/db/.AppleSetupDone"
do
	[ -e "$f" ] || continue
	printf "  removing %s\n" "$f"
	unlock_rm "$f"
done
find /Volumes -maxdepth 8 \( -name '.AppleSetupDone' -o -name '.AppleDiagnosticsSetupDone' \) 2>/dev/null | while IFS= read -r f; do
	[ -n "$f" ] || continue
	unlock_rm "$f"
done

# Sonoma+ needs this or it can skip Setup Assistant and land on loginwindow
for db in \
	"$DATA_VOL/private/var/db" \
	"$DATA_VOL/var/db" \
	"/Volumes/Data 1/private/var/db" \
	"/Volumes/Data/private/var/db" \
	"$SYS_VOL/System/Volumes/Data/private/var/db"
do
	mkdir -p "$db" 2>/dev/null
	touch "$db/.RunLanguageChooserToo" 2>/dev/null
done
printf "${GRN}  ✓ .RunLanguageChooserToo written${NC}\n"

if [ -e "$DATA_VOL/private/var/db/.AppleSetupDone" ] || [ -e "$DATA_VOL/var/db/.AppleSetupDone" ]; then
	printf "${RED}  ✗ .AppleSetupDone still present on ${DATA_VOL}${NC}\n"
else
	printf "${GRN}  ✓ .AppleSetupDone removed — Setup Assistant will run${NC}\n"
fi
printf "\n"

# ═══════════════════════════════════════════════════════
# SNAPSHOT: If we modified the system volume, bless it
# ═══════════════════════════════════════════════════════
if [ "$SYS_WRITABLE" = true ]; then
	printf "${YEL}[8] Blessing modified system volume...${NC}\n"
	if bless --mount "$SYS_VOL" --create-snapshot 2>/dev/null; then
		printf "${GRN}  ✓ System volume snapshot created${NC}\n"
	elif bless --folder "$SYS_VOL/System/Library/CoreServices" --bootefi --create-snapshot 2>/dev/null; then
		printf "${GRN}  ✓ System volume snapshot created (Intel fallback)${NC}\n"
	else
		printf "${YEL}  ⚠ Could not create snapshot — changes may not persist${NC}\n"
	fi
	printf "\n"
fi

# ═══════════════════════════════════════════════════════
printf "${GRN}╔═══════════════════════════════════════════════════╗${NC}\n"
printf "${GRN}║       Reclaim complete.                           ║${NC}\n"
printf "${GRN}╚═══════════════════════════════════════════════════╝${NC}\n"
printf "\n"

if [ "$SYS_WRITABLE" != true ]; then
	printf "${YEL}NOTE: System volume was read-only. The SIP/SSV disable${NC}\n"
	printf "${YEL}may need a reboot to take effect. If MDM still appears:${NC}\n"
	printf "${YEL}  1. Reboot into Recovery Mode again${NC}\n"
	printf "${YEL}  2. Run this script a second time${NC}\n"
	printf "${YEL}  (The system volume should be writable on the 2nd run)${NC}\n"
	printf "\n"
fi

printf "${CYAN}Close this terminal and restart this Mac.${NC}\n"
printf "${CYAN}It will boot into a clean Setup Assistant — ready for its next life.${NC}\n"
printf "\n"
printf "${CYAN}After setup, re-enable SIP from Recovery:${NC}\n"
printf "  ${GRN}csrutil enable${NC}\n"
printf "  ${GRN}csrutil authenticated-root enable${NC}\n"
printf "\n"
