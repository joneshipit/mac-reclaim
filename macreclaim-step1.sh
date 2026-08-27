#!/bin/bash

# MacReclaim - Enterprise Mac Recovery (Step 1 of 3)
# Run from Recovery Mode.
# Strips stale MDM enrollment data so abandoned enterprise
# MacBooks can be reclaimed instead of becoming e-waste.

# Do not rename "Macintosh HD - Data" → "Data". If /Volumes/Data already
# exists, that rename mounts the real volume as "Data 1" and later steps miss it.
mount_macos_volumes() {
	local ident
	diskutil mount "Macintosh HD" 2>/dev/null
	diskutil mount "Macintosh HD - Data" 2>/dev/null
	diskutil mount "Data" 2>/dev/null
	diskutil mount "Data 1" 2>/dev/null
	for ident in $(diskutil list 2>/dev/null | sed -n 's/.*\(disk[0-9]*s[0-9]*\)$/\1/p'); do
		diskutil mount "$ident" 2>/dev/null
	done
}

find_data_volume() {
	local vol best="" best_score=-1 score

	for vol in /Volumes/*; do
		[ -d "$vol" ] || continue
		case "$vol" in
			"/Volumes/macOS Base System"|"/Volumes/Preboot"|"/Volumes/Recovery"|"/Volumes/VM") continue ;;
		esac
		[ -d "$vol/System/Library/CoreServices" ] && continue
		[ -d "$vol/private/var/db/dslocal/nodes/Default" ] || continue
		score=10
		[ -d "$vol/Users" ] && score=$((score + 20))
		[ -f "$vol/private/var/db/.AppleSetupDone" ] && score=$((score + 5))
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

do_reclaim() {
	mount_macos_volumes
	if ! find_data_volume; then
		echo "ERROR: Could not find a macOS Data volume (Data / Data 1 / Macintosh HD - Data)."
		exit 1
	fi
	find_system_volume
	echo "Using Data volume: $DATA_VOL"
	echo "Using System volume: $SYS_VOL"

	dscl_path="$DATA_VOL/private/var/db/dslocal/nodes/Default"

	echo -n "Enter username for temporary admin account: "
	read TEMP_USER
	echo -n "Enter password: "
	read -s TEMP_PASS
	echo

	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$TEMP_USER"
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$TEMP_USER" UserShell "/bin/zsh"
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$TEMP_USER" RealName "$TEMP_USER"
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$TEMP_USER" UniqueID "501"
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$TEMP_USER" PrimaryGroupID "20"
	mkdir -p "$DATA_VOL/Users/$TEMP_USER"
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$TEMP_USER" NFSHomeDirectory "/Users/$TEMP_USER"
	dscl -f "$dscl_path" localhost -passwd "/Local/Default/Users/$TEMP_USER" "$TEMP_PASS"
	dscl -f "$dscl_path" localhost -append "/Local/Default/Groups/admin" GroupMembership "$TEMP_USER"

	echo "0.0.0.0 deviceenrollment.apple.com" >>"$SYS_VOL/etc/hosts"
	echo "0.0.0.0 mdmenrollment.apple.com" >>"$SYS_VOL/etc/hosts"
	echo "0.0.0.0 iprofiles.apple.com" >>"$SYS_VOL/etc/hosts"

	touch "$DATA_VOL/private/var/db/.AppleSetupDone"
	rm -f "$SYS_VOL/var/db/ConfigurationProfiles/Settings/.cloudConfigHasActivationRecord"
	rm -f "$SYS_VOL/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
	touch "$SYS_VOL/var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled"
	touch "$SYS_VOL/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound"

	erase_assistant="$SYS_VOL/System/Library/CoreServices/EraseAssistant.app/Contents/MacOS/EraseAssistant"
	if [ -f "$erase_assistant" ]; then
		mv "$erase_assistant" "${erase_assistant}.bak"
		echo '#!/bin/bash\nexit 0' > "$erase_assistant"
		chmod +x "$erase_assistant"
	fi

	erase_plist="$SYS_VOL/System/Library/LaunchDaemons/com.apple.EraseAssistant.plist"
	if [ -f "$erase_plist" ]; then
		mv "$erase_plist" "${erase_plist}.bak"
	fi

	profiles_dir="$SYS_VOL/var/db/ConfigurationProfiles/Settings"
	chflags schg "$profiles_dir"/.cloudConfig* 2>/dev/null
	chmod 000 "$profiles_dir" 2>/dev/null

	setup_done="$DATA_VOL/private/var/db/.AppleSetupDone"
	chflags uchg "$setup_done" 2>/dev/null
}

do_reclaim

echo "DONE. RESTART THE MACBOOK — this enterprise Mac has been reclaimed."
