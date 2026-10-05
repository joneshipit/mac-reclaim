# MacReclaim — Enterprise Mac Recovery

Stop perfectly good enterprise MacBooks from becoming e-waste.

Millions of enterprise MacBooks are decommissioned every year. When IT departments fail to properly release them from MDM before disposal, these machines become "bricks" — unable to complete setup because they still try to phone home to a defunct server.

B2B lot buyers, refurbishers, and recyclers end up with pallets of non-functional MacBooks headed for the shredder, not because the hardware is bad, but because of a stale software flag.

**MacReclaim fixes that.**

## The Problem

- Enterprise leases expire. MacBooks are sold in bulk to lot buyers.
- IT wipes the drive but forgets to release the serial from MDM.
- The MacBook boots up, connects to WiFi, and immediately tries to enroll in an MDM that no longer exists or no longer recognizes this device.
- Setup Assistant blocks the user. The machine is unusable.
- It gets palletized and shipped to a recycler. Or worse, a landfill.

This is not a security bypass. This is **e-waste prevention**. The original organization abandoned these machines. MacReclaim gives them a second life.

## How It Works

MacReclaim is a 3-step process that strips stale enrollment data and presents a clean macOS Setup Assistant — just like a brand new Mac.

| Step | Where | What |
|------|-------|------|
| 1 | Recovery Mode | Create temporary account, block MDM domains, set bypass markers |
| 2 | Within macOS | Disable MDM daemons, install hosts guard, remove config profiles |
| 3 | Recovery Mode (SIP off) | Delete all accounts, nuke enrollment data, clear NVRAM |

**Result:** A fully functional MacBook that can be set up with Apple ID, iCloud, Touch ID — everything works. MDM enrollment is skipped.

## Clean Setup (3 Steps)

### 1. Boot into Recovery Mode & Run Step 1

| Mac Type | How to Enter Recovery |
|----------|----------------------|
| **Apple Silicon** (M1/M2/M3/M4) | Shut down completely. Press and **hold the Power button** until "Loading startup options." Select **Options** → **Continue**. |
| **Intel** | Shut down completely. Press Power, then immediately **hold ⌘ + R** until the Apple logo appears. |

Open Terminal from the menu bar: **Utilities → Terminal**

```bash
curl -L https://raw.githubusercontent.com/joneshipit/bypass-mdm-clean/main/bypass-mdm-clean.sh -o macreclaim.sh && chmod +x ./macreclaim.sh && ./macreclaim.sh
```

Follow the prompts to create a temporary user account. Close Terminal and reboot into macOS.

### 2. Log In & Run Step 2

Log in with your newly created temporary user account. Skip all setup prompts.

Open **Terminal** and run:

```bash
curl -L https://raw.githubusercontent.com/joneshipit/bypass-mdm-clean/main/step2-clean-setup.sh -o step2.sh && chmod +x step2.sh && sudo ./step2.sh
```

**Important (Apple Silicon only):** Before shutting down, create an admin account for SIP authentication:

```bash
sudo sysadminctl -addUser <admin_user> -password <password> -admin
```

**Shut down** the Mac (don't just reboot).

### 3. Boot into Recovery Mode & Disable SIP

Boot into Recovery Mode again. Open Terminal.

**First, disable SIP:**

```bash
csrutil disable
csrutil authenticated-root disable
```

**Then run Step 3:**

```bash
curl -L https://raw.githubusercontent.com/joneshipit/bypass-mdm-clean/main/step3-cleanup.sh -o step3.sh && chmod +x step3.sh && ./step3.sh
```

Close Terminal and reboot.

### 4. Setup Assistant

The Mac boots into a **completely clean Setup Assistant** — just like a brand new Mac. Create your account with Apple ID, Touch ID, Siri, iCloud. MDM enrollment will be skipped.

### 5. Re-enable SIP (recommended)

After setup is complete, boot into Recovery one more time:

```bash
csrutil enable
csrutil authenticated-root enable
```

## Troubleshooting

### "No authenticated users" when running csrutil

Create an account with `sysadminctl` from within macOS first:

```bash
sudo sysadminctl -addUser <admin_user> -password <password> -admin
```

Then boot into Recovery and authenticate with this account.

### MDM still appears in Setup Assistant

1. Boot into the Mac (it may let you past the error with "Continue")
2. Open Terminal and verify: `cat /etc/hosts` — MDM domains should be listed
3. If not, run: `sudo /usr/local/bin/mdm-hosts-guard.sh` to reapply

### MDM prompts appear after setup

The hosts guard daemon should prevent this. Verify it's running:

```bash
sudo launchctl list | grep mdm-hosts-guard
```

## Uninstall

```bash
sudo rm /usr/local/bin/mdm-hosts-guard.sh
sudo rm /Library/LaunchDaemons/com.joneshipit.mdm-hosts-guard.plist
sudo rm /usr/local/bin/block-erase.sh
sudo rm /Library/LaunchDaemons/com.joneshipit.block-erase.plist
sudo rm "/Library/Managed Preferences/com.apple.SetupAssistant.plist"
sudo rm /Library/Preferences/com.apple.SetupAssistant.plist
```

Then edit `/etc/hosts` and remove the `0.0.0.0` lines.

## The Bigger Picture

Every MacBook reclaimed is one less piece of e-waste. The average enterprise MacBook has a 5-7 year useful life. Most are decommissioned after 3-4 years — at peak performance. With MacReclaim, refurbishers can:

- ✅ Test and certify hardware
- ✅ Reset software to factory-fresh state
- ✅ Sell to consumers, schools, or small businesses
- ✅ Keep electronics out of landfills

## Disclaimer

This tool is intended solely for the recovery of enterprise assets that have been abandoned by their original organization. You must have legal ownership or authorization to use this software on any device. The original organization's MDM server no longer serves this device. We do not condone theft or unauthorized use of equipment.

## Credits

- Original concept: [Assaf Dori](https://github.com/assafdori/bypass-mdm)
- MacReclaim initiative: [joneshipit](https://github.com/joneshipit)
