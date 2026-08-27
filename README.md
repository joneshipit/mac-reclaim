# MacReclaim — Enterprise Mac Recovery

Stop perfectly good enterprise MacBooks from becoming e-waste.

Millions of enterprise MacBooks are decommissioned every year. When IT departments fail to properly release them from MDM before disposal, these machines become "bricks" — unable to complete setup because they still try to phone home to a defunct server.

**MacReclaim fixes that.** One paste from Recovery. It finds the Data volume even if Recovery named it `Data 1`, wipes leftover accounts, and boots a clean Setup Assistant (Hello / create account) on Sonoma 14.x.

## One shot (Recovery)

| Mac Type | How to enter Recovery |
|----------|----------------------|
| **Apple Silicon** (M1/M2/M3/M4) | Shut down. Press and **hold the Power button** until "Loading startup options." **Options** → **Continue**. |
| **Intel** | Shut down. Power on and immediately **hold ⌘ + R**. |

Open **Utilities → Terminal** and paste:

```bash
curl -L https://raw.githubusercontent.com/joneshipit/mac-reclaim/main/macreclaim.sh -o macreclaim.sh && chmod +x macreclaim.sh && ./macreclaim.sh
```

Close Terminal and restart. You should get **Hello / language / create account** — not a login box.

Optional (lets the script also rewrite system-volume hosts and MDM daemons):

```bash
csrutil disable
csrutil authenticated-root disable
```

Then run the same `macreclaim.sh` curl. Data-volume work (users + Setup Assistant) still runs if SIP stays on.

After setup, re-enable SIP from Recovery:

```bash
csrutil enable
csrutil authenticated-root enable
```

## What it does

- Detects the APFS **Data** volume by role (`Data`, `Data 1`, `Macintosh HD - Data` — you do not pick)
- Deletes every local user with UniqueID ≥ 500 (Sonoma will not show Hello if any remain)
- Unlocks and removes `.AppleSetupDone` (step-1 used to lock this with `uchg`)
- Writes `.RunLanguageChooserToo`
- Strips `DidSeeCloudSetup` skip keys that dump you at an empty login window
- Clears stale MDM enrollment markers and blocks MDM domains when the system volume is writable

## Legacy 3-step scripts

`macreclaim-step1.sh` / `step2.sh` / `step3.sh` are still in the repo. Prefer the one-shot script above. Step 3 and `macreclaim-force-setup.sh` now trampoline into `macreclaim.sh`.

## Troubleshooting

### Empty login box instead of Setup Assistant

You still have a local user (often the SIP admin from `sysadminctl`) or `.AppleSetupDone` on `Data 1`. Re-run the one-shot curl from Recovery. If it prints leftover users, that is the blocker.

### MDM still appears in Setup Assistant

1. Boot past the error with Continue if you can
2. `cat /etc/hosts` — MDM domains should be `0.0.0.0`
3. Re-run the one-shot from Recovery with SIP off so it can write `/etc/hosts`

## Uninstall

```bash
sudo rm /usr/local/bin/mdm-hosts-guard.sh
sudo rm /Library/LaunchDaemons/com.joneshipit.mdm-hosts-guard.plist
sudo rm /usr/local/bin/block-erase.sh
sudo rm /Library/LaunchDaemons/com.joneshipit.block-erase.plist
sudo rm "/Library/Managed Preferences/com.apple.SetupAssistant.plist"
sudo rm /Library/Preferences/com.apple.SetupAssistant.plist
```

Then remove the `0.0.0.0` MDM lines from `/etc/hosts`.

## Disclaimer

This tool is intended solely for the recovery of enterprise assets that have been abandoned by their original organization. You must have legal ownership or authorization to use this software on any device.

## Credits

- MacReclaim initiative: [joneshipit](https://github.com/joneshipit)
