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
# PHASE 0: Mount and prepare volumes
# ═══════════════════════════════════════════════════════
printf "${YEL}[0] Mounting volumes...${NC}\n"

diskutil mount "Macintosh HD" 2>/dev/null
diskutil mount "Macintosh HD - Data" 2>/dev/null
diskutil mount "Data" 2>/dev/null

if [ -d "/Volumes/Macintosh HD - Data" ]; then
	diskutil rename "Macintosh HD - Data" "Data" 2>/dev/null
fi

if [ ! -d "/Volumes/Data" ]; then
	printf "${RED}ERROR: /Volumes/Data not found. Is macOS installed?${NC}\n"
	exit 1
fi

printf "${GRN}  ✓ Data volume ready${NC}\n"

if [ ! -d "/Volumes/Macintosh HD" ]; then
	printf "${YEL}  ⚠ System volume not mounted at /Volumes/Macintosh HD${NC}\n"
	SYS_AVAILABLE=false
else
	printf "${GRN}  ✓ System volume accessible${NC}\n"
	SYS_AVAILABLE=true
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
	mount -uw "/Volumes/Macintosh HD" 2>/dev/null
	if touch "/Volumes/Macintosh HD/.rw_test" 2>/dev/null; then
		rm -f "/Volumes/Macintosh HD/.rw_test"
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

data_profiles="/Volumes/Data/private/var/db/ConfigurationProfiles"
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
	sys_profiles="/Volumes/Macintosh HD/var/db/ConfigurationProfiles"
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
		for dir in "/Volumes/Macintosh HD/System/Library/LaunchDaemons" "/Volumes/Macintosh HD/System/Library/LaunchAgents"; do
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

managed_dir="/Volumes/Data/Library/Managed Preferences"
mkdir -p "$managed_dir" 2>/dev/null

cat > "$managed_dir/com.apple.SetupAssistant.plist" << 'SKIPEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SkipCloudSetup</key>
	<true/>
	<key>SkipDeviceManagement</key>
	<true/>
	<key>DidSeeCloudSetup</key>
	<true/>
</dict>
</plist>
SKIPEOF
printf "${GRN}  ✓ Skip keys written to Managed Preferences${NC}\n"

data_prefs="/Volumes/Data/Library/Preferences"
mkdir -p "$data_prefs" 2>/dev/null
cp "$managed_dir/com.apple.SetupAssistant.plist" "$data_prefs/com.apple.SetupAssistant.plist" 2>/dev/null

if [ "$SYS_WRITABLE" = true ]; then
	sys_managed="/Volumes/Macintosh HD/Library/Managed Preferences"
	mkdir -p "$sys_managed" 2>/dev/null
	cp "$managed_dir/com.apple.SetupAssistant.plist" "$sys_managed/" 2>/dev/null
	printf "${GRN}  ✓ Skip keys written to system volume${NC}\n"
fi
printf "\n"

# ═══════════════════════════════════════════════════════
# ATTACK 5: Clear WiFi networks
# ═══════════════════════════════════════════════════════
printf "${YEL}[6] Clearing saved WiFi networks...${NC}\n"

rm -f "/Volumes/Data/private/var/db/SystemConfiguration/com.apple.wifi.known-networks.plist" 2>/dev/null
rm -f "/Volumes/Data/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist" 2>/dev/null
rm -f "/Volumes/Data/Library/Preferences/SystemConfiguration/com.apple.wifi.message-tracer.plist" 2>/dev/null
printf "${GRN}  ✓ WiFi networks cleared${NC}\n"
printf "\n"

# ═══════════════════════════════════════════════════════
# CLEANUP: Delete all users & remove .AppleSetupDone
# ═══════════════════════════════════════════════════════
printf "${YEL}[7] Deleting temporary accounts...${NC}\n"

DSLOCAL="/Volumes/Data/private/var/db/dslocal/nodes/Default/users"
deleted=0
for plist in "$DSLOCAL"/*.plist; do
	[ -f "$plist" ] || continue
	username=$(basename "$plist" .plist)
	case "$username" in
		_*|root|daemon|nobody|Guest) continue ;;
	esac
	printf "  ${YEL}Deleting: $username${NC}\n"
	rm -f "$plist"
	rm -rf "/Volumes/Data/Users/$username" 2>/dev/null
	deleted=$((deleted + 1))
done

if [ $deleted -gt 0 ]; then
	printf "${GRN}  ✓ Deleted $deleted account(s)${NC}\n"
else
	printf "${BLU}  ℹ No accounts to delete${NC}\n"
fi

rm -f /Volumes/Data/private/var/db/.AppleSetupDone 2>/dev/null
printf "${GRN}  ✓ Removed .AppleSetupDone${NC}\n"
printf "\n"

# ═══════════════════════════════════════════════════════
# SNAPSHOT: If we modified the system volume, bless it
# ═══════════════════════════════════════════════════════
if [ "$SYS_WRITABLE" = true ]; then
	printf "${YEL}[8] Blessing modified system volume...${NC}\n"
	if bless --mount "/Volumes/Macintosh HD" --create-snapshot 2>/dev/null; then
		printf "${GRN}  ✓ System volume snapshot created${NC}\n"
	elif bless --folder "/Volumes/Macintosh HD/System/Library/CoreServices" --bootefi --create-snapshot 2>/dev/null; then
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
