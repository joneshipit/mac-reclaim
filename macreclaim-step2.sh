#!/bin/bash

# MacReclaim - Enterprise Mac Recovery (Step 2 of 3)
# Run from within macOS (as the temp user from Step 1).
# Removes stale MDM enrollment so abandoned enterprise
# MacBooks can be reclaimed instead of becoming e-waste.
#
# This script:
#   1. Permanently blocks MDM domains in /etc/hosts
#   2. Installs a hosts guard daemon for boot persistence
#   3. Disables MDM enrollment daemons via launchctl
#   4. Writes Setup Assistant skip keys (managed preferences)
#   5. Removes stale MDM configuration profiles
#   6. Optionally installs reset protection
#
# Step 3 (from Recovery) handles user deletion and final cleanup.
# Must be run with sudo.

RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

error_exit() {
	echo -e "${RED}ERROR: $1${NC}" >&2
	exit 1
}
warn() { echo -e "${YEL}WARNING: $1${NC}"; }
success() { echo -e "${GRN}✓ $1${NC}"; }
info() { echo -e "${BLU}ℹ $1${NC}"; }

# Must be root
if [ "$(id -u)" -ne 0 ]; then
	error_exit "This script must be run with sudo. Try: sudo ./step2.sh"
fi

# Header
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  MacReclaim - Enterprise Mac Recovery (Step 2)   ║${NC}"
echo -e "${CYAN}║  Preventing e-waste by reclaiming MacBooks       ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}This will:${NC}"
echo -e "  • Permanently block stale MDM domains"
echo -e "  • Install MDM hosts guard daemon"
echo -e "  • Disable orphaned MDM enrollment daemons"
echo -e "  • Write Setup Assistant skip keys"
echo -e "  • Remove stale MDM configuration profiles"
echo ""
echo -e "${YEL}After Step 3 (Recovery), this Mac will present a clean${NC}"
echo -e "${YEL}macOS setup — Apple ID, Touch ID, Siri — with no MDM.${NC}"
echo ""
read -p "Continue? (y/n): " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
	echo "Aborted."
	exit 0
fi

echo ""

# ── Step 1: Block MDM domains in /etc/hosts ──
info "Blocking stale MDM domains in /etc/hosts..."

mdm_domains=(
	"deviceenrollment.apple.com"
	"mdmenrollment.apple.com"
	"iprofiles.apple.com"
	"acmdm.apple.com"
	"axm-adm-mdm.apple.com"
	"axm-adm-enroll.apple.com"
	"albert.apple.com"
	"identity.apple.com"
)

blocked_count=0
for domain in "${mdm_domains[@]}"; do
	if ! grep -qF "$domain" /etc/hosts 2>/dev/null; then
		echo "0.0.0.0 $domain" >>/etc/hosts || warn "Failed to write $domain to /etc/hosts"
		blocked_count=$((blocked_count + 1))
	fi
done
if grep -qF "deviceenrollment.apple.com" /etc/hosts 2>/dev/null; then
	success "Blocked ${#mdm_domains[@]} MDM domains ($blocked_count new entries added)"
else
	error_exit "Failed to write to /etc/hosts — SIP or permissions may be blocking writes"
fi
echo ""

# ── Step 2: Install hosts guard daemon ──
info "Installing MDM hosts guard daemon..."

mkdir -p /usr/local/bin || error_exit "Failed to create /usr/local/bin"

cat > /usr/local/bin/mdm-hosts-guard.sh << 'HOSTSGUARD'
#!/bin/bash
domains="deviceenrollment.apple.com mdmenrollment.apple.com iprofiles.apple.com acmdm.apple.com axm-adm-mdm.apple.com axm-adm-enroll.apple.com albert.apple.com identity.apple.com"
changed=0
for domain in $domains; do
    if ! grep -qF "$domain" /etc/hosts 2>/dev/null; then
        echo "0.0.0.0 $domain" >> /etc/hosts
        changed=1
    fi
done
if [ "$changed" -eq 1 ]; then
    logger -t mdm-hosts-guard "Re-applied MDM domain blocks to /etc/hosts"
fi
HOSTSGUARD
chmod +x /usr/local/bin/mdm-hosts-guard.sh

cat > /Library/LaunchDaemons/com.joneshipit.mdm-hosts-guard.plist << 'HOSTSPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.joneshipit.mdm-hosts-guard</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>/usr/local/bin/mdm-hosts-guard.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>WatchPaths</key>
	<array>
		<string>/etc/hosts</string>
	</array>
</dict>
</plist>
HOSTSPLIST

chown root:wheel /Library/LaunchDaemons/com.joneshipit.mdm-hosts-guard.plist
chmod 644 /Library/LaunchDaemons/com.joneshipit.mdm-hosts-guard.plist

launchctl bootstrap system /Library/LaunchDaemons/com.joneshipit.mdm-hosts-guard.plist 2>/dev/null || \
	launchctl load -w /Library/LaunchDaemons/com.joneshipit.mdm-hosts-guard.plist 2>/dev/null

success "MDM hosts guard installed"
echo ""

# ── Step 3: Remove stale MDM configuration profiles ──
info "Removing stale MDM configuration profiles..."

profiles remove -all 2>/dev/null && success "Removed stale enrolled profiles" || info "No stale profiles to remove (or SIP blocked)"

profiles_dir="/var/db/ConfigurationProfiles"
if [ -d "$profiles_dir" ]; then
	rm -f "$profiles_dir/Settings/.cloudConfigHasActivationRecord" 2>/dev/null
	rm -f "$profiles_dir/Settings/.cloudConfigRecordFound" 2>/dev/null
	rm -f "$profiles_dir/Settings/.cloudConfigActivationRecord" 2>/dev/null
	touch "$profiles_dir/Settings/.cloudConfigProfileInstalled" 2>/dev/null
	touch "$profiles_dir/Settings/.cloudConfigRecordNotFound" 2>/dev/null
	if [ -f "$profiles_dir/Settings/.cloudConfigRecordNotFound" ]; then
		success "MDM reclaim markers set"
	else
		warn "Could not write reclaim markers (SIP may be blocking — Step 3 will handle this)"
	fi
else
	warn "ConfigurationProfiles directory not found — Step 3 will handle this from Recovery"
fi
echo ""

# ── Step 4: Disable orphaned MDM enrollment daemons ──
info "Disabling orphaned MDM enrollment daemons..."

mdm_daemons=(
	"com.apple.cloudconfigurationd"
	"com.apple.DeviceManagement.enrollmentd"
	"com.apple.ManagedClient.cloudconfigurationd"
	"com.apple.ManagedClient.enroll"
	"com.apple.ManagedClient"
	"com.apple.ManagedClient.startup"
	"com.apple.mdmclient.daemon"
	"com.apple.mdmclient"
)

disabled_count=0
for svc in "${mdm_daemons[@]}"; do
	if launchctl disable "system/$svc" 2>/dev/null; then
		disabled_count=$((disabled_count + 1))
	fi
	launchctl bootout "system/$svc" 2>/dev/null
done

mdm_agents=("com.apple.mdmclient.agent")
logged_in_uid=$(id -u "${SUDO_USER:-}" 2>/dev/null || echo "")
if [ -n "$logged_in_uid" ]; then
	for svc in "${mdm_agents[@]}"; do
		if launchctl disable "gui/$logged_in_uid/$svc" 2>/dev/null; then
			disabled_count=$((disabled_count + 1))
		fi
		launchctl bootout "gui/$logged_in_uid/$svc" 2>/dev/null
	done
fi

if [ $disabled_count -gt 0 ]; then
	success "Disabled $disabled_count orphaned MDM services via launchctl"
else
	warn "Could not disable services (may require different approach on this macOS version)"
fi
echo ""

# ── Step 5: Write Setup Assistant skip keys ──
info "Writing Setup Assistant skip keys..."

managed_dir="/Library/Managed Preferences"
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

if [ -f "$managed_dir/com.apple.SetupAssistant.plist" ]; then
	success "Skip keys written to $managed_dir"
else
	warn "Failed to write skip keys"
fi

cp "$managed_dir/com.apple.SetupAssistant.plist" /Library/Preferences/com.apple.SetupAssistant.plist 2>/dev/null
success "Skip keys copied to /Library/Preferences"
echo ""

# ── Step 6: Flush DNS cache ──
info "Flushing DNS cache..."
dscacheutil -flushcache 2>/dev/null
killall -HUP mDNSResponder 2>/dev/null
success "DNS cache flushed — hosts blocks active immediately"
echo ""

# ── Step 7: Optional reset protection ──
echo -e "${CYAN}Would you like to prevent accidental factory reset?${NC}"
echo -e "${BLU}This silently blocks 'Erase All Content and Settings'.${NC}"
echo -e "${BLU}Useful for refurbishers preparing units for sale.${NC}"
echo ""
read -p "Install reset protection? (y/n): " install_rp

if [ "$install_rp" = "y" ] || [ "$install_rp" = "Y" ]; then
	info "Installing reset protection..."

	erase_services=(
		"com.apple.EraseAssistant"
		"com.apple.eraseassistant"
		"com.apple.erasetool"
		"com.apple.systemreset"
		"com.apple.MobileAsset.EraseAssistant"
	)
	for svc in "${erase_services[@]}"; do
		launchctl disable "system/$svc" 2>/dev/null
		launchctl disable "gui/$(id -u "${SUDO_USER:-}")/$svc" 2>/dev/null
	done
	success "Erase services disabled via launchctl"

	cat > /usr/local/bin/block-erase.sh << 'BLOCKSCRIPT'
#!/bin/bash
for proc in "Erase Assistant" "EraseAssistant" "erasetool" "systemreset"; do
    pkill -9 -f "$proc" 2>/dev/null && logger -t block-erase "Blocked: $proc"
done
BLOCKSCRIPT
	chmod +x /usr/local/bin/block-erase.sh

	cat > /Library/LaunchDaemons/com.joneshipit.block-erase.plist << 'ERASEPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.joneshipit.block-erase</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>/usr/local/bin/block-erase.sh</string>
	</array>
	<key>StartInterval</key>
	<integer>1</integer>
</dict>
</plist>
ERASEPLIST

	chown root:wheel /Library/LaunchDaemons/com.joneshipit.block-erase.plist
	chmod 644 /Library/LaunchDaemons/com.joneshipit.block-erase.plist

	launchctl bootstrap system /Library/LaunchDaemons/com.joneshipit.block-erase.plist 2>/dev/null || \
		launchctl load -w /Library/LaunchDaemons/com.joneshipit.block-erase.plist 2>/dev/null

	success "Reset protection installed"
else
	info "Skipped reset protection"
fi
echo ""

# ── Done ──
echo -e "${GRN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${GRN}║       Step 2 Complete!                            ║${NC}"
echo -e "${GRN}╚═══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Next:${NC}"
echo ""
echo -e "  ${YEL}IMPORTANT (Apple Silicon only):${NC}"
echo -e "  Before shutting down, create an admin account for SIP auth:"
echo ""
echo -e "    ${GRN}sudo sysadminctl -addUser <admin_user> -password <password> -admin${NC}"
echo ""
echo -e "  1. ${YEL}Shut down${NC} the Mac (not just reboot)"
echo -e "  2. Boot into ${GRN}Recovery Mode${NC}"
echo -e "     (hold Power button → Options → Continue)"
echo -e "  3. Open Terminal and disable SIP:"
echo -e "     ${GRN}csrutil disable${NC}"
echo -e "     ${GRN}csrutil authenticated-root disable${NC}"
echo -e "  4. Then run Step 3:"
echo ""
echo -e "  ${YEL}curl -L https://raw.githubusercontent.com/joneshipit/mac-reclaim/main/macreclaim-step3.sh -o step3.sh && chmod +x step3.sh && ./step3.sh${NC}"
echo ""
echo -e "  5. Reboot → clean Setup Assistant"
echo ""
echo -e "${CYAN}To uninstall MacReclaim later:${NC}"
echo -e "  /usr/local/bin/mdm-hosts-guard.sh"
echo -e "  /Library/LaunchDaemons/com.joneshipit.mdm-hosts-guard.plist"
echo -e "  /usr/local/bin/block-erase.sh (if installed)"
echo -e "  /Library/LaunchDaemons/com.joneshipit.block-erase.plist (if installed)"
echo -e "  /Library/Managed Preferences/com.apple.SetupAssistant.plist"
echo -e "  Then remove the 0.0.0.0 lines from /etc/hosts"
echo ""
