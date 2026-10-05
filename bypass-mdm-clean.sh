#!/bin/bash

# MacReclaim - Enterprise Mac Recovery (Step 1 of 3)
# Run from Recovery Mode.
# Strips stale MDM enrollment data so abandoned enterprise
# MacBooks can be reclaimed instead of becoming e-waste.

do_reclaim() {
	if [ -d "/Volumes/Macintosh HD - Data" ]; then
		diskutil rename "Macintosh HD - Data" "Data"
	fi

	dscl_path='/Volumes/Data/private/var/db/dslocal/nodes/Default'

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
	mkdir -p "/Volumes/Data/Users/$TEMP_USER"
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$TEMP_USER" NFSHomeDirectory "/Users/$TEMP_USER"
	dscl -f "$dscl_path" localhost -passwd "/Local/Default/Users/$TEMP_USER" "$TEMP_PASS"
	dscl -f "$dscl_path" localhost -append "/Local/Default/Groups/admin" GroupMembership "$TEMP_USER"

	echo "0.0.0.0 deviceenrollment.apple.com" >>/Volumes/Macintosh\ HD/etc/hosts
	echo "0.0.0.0 mdmenrollment.apple.com" >>/Volumes/Macintosh\ HD/etc/hosts
	echo "0.0.0.0 iprofiles.apple.com" >>/Volumes/Macintosh\ HD/etc/hosts

	touch /Volumes/Data/private/var/db/.AppleSetupDone
	rm -f "/Volumes/Macintosh HD/var/db/ConfigurationProfiles/Settings/.cloudConfigHasActivationRecord"
	rm -f "/Volumes/Macintosh HD/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
	touch "/Volumes/Macintosh HD/var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled"
	touch "/Volumes/Macintosh HD/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound"

	erase_assistant="/Volumes/Macintosh HD/System/Library/CoreServices/EraseAssistant.app/Contents/MacOS/EraseAssistant"
	if [ -f "$erase_assistant" ]; then
		mv "$erase_assistant" "${erase_assistant}.bak"
		echo '#!/bin/bash\nexit 0' > "$erase_assistant"
		chmod +x "$erase_assistant"
	fi

	erase_plist="/Volumes/Macintosh HD/System/Library/LaunchDaemons/com.apple.EraseAssistant.plist"
	if [ -f "$erase_plist" ]; then
		mv "$erase_plist" "${erase_plist}.bak"
	fi

	profiles_dir="/Volumes/Macintosh HD/var/db/ConfigurationProfiles/Settings"
	chflags schg "$profiles_dir"/.cloudConfig* 2>/dev/null
	chmod 000 "$profiles_dir" 2>/dev/null

	setup_done="/Volumes/Data/private/var/db/.AppleSetupDone"
	chflags uchg "$setup_done" 2>/dev/null
}

do_reclaim

echo "DONE. RESTART THE MACBOOK — this enterprise Mac has been reclaimed."
