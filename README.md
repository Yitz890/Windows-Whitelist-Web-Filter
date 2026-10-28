# Windows 11 Lockdown & Whitelist Suite

A lightweight endpoint restriction and policy management suite for Windows 10 & 11 (Home and Pro). It enforces a strict **URL whitelist** across major web browsers, restricts **portable executable execution**, blocks the **Microsoft Store**, and terminates **USB/external drive processes** in real-time for a targeted standard user account while leaving administrative and other user accounts unrestricted.

---

## Repository Files

| File | Description |
| :--- | :--- |
| `Lockdown_Master.bat` | Deployment, policy engine, and administration script. |
| `Undo_Lockdown.bat` | Complete teardown and system restoration script. |
| `allowed_sites.txt` | Whitelist configuration containing approved domains, CDNs, and paths. |

---

## System Requirements

- **Operating System:** Windows 10 or Windows 11 (Home & Pro).
- **Target Account:** Must be a **Standard Local User** account. (If the user is an Administrator, they can bypass or revoke policies).
- **Privileges:** Administrator access is required to run the scripts. Both files automatically request UAC elevation if launched unelevated.

---

## How It Works

1. **Per-User Web Filter:** Writes `URLBlocklist` (`http://*`, `https://*`) and `URLAllowlist` policies into the designated target profile's registry hive (`HKU\<SID>`). Supported browsers:
   - Google Chrome
   - Microsoft Edge
   - Brave Browser
   - Mozilla Firefox & Zen Browser (via Mozilla `WebsiteFilter` policies)
2. **Execution Guard:**
   - Denies binary execution flags (`icacls /deny (OI)(X)`) on writeable profile directories (`Downloads`, `Desktop`, `Documents`, and cloud folders).
   - Blocks per-user MSI package installations (`DisableUserInstalls`).
   - Disables access to the Microsoft Store (`RemoveWindowsStore`).
3. **USB & Store Process Watchdog:** A background loop monitors process creation every 0.4 seconds and terminates any executable owned by the target user that is launched from non-`C:\` drives (e.g., USB sticks) or `WinStore.App.exe`, displaying an `ACCESS DENIED` notification.

---

## Setup Guide

### Step 1: Clone or Download the Repository
Ensure all three files are in the same directory:
```text
Lockdown-Suite/
├── Lockdown_Master.bat
├── Undo_Lockdown.bat
└── allowed_sites.txt
```

### Step 2: Configure `allowed_sites.txt`
Edit `allowed_sites.txt` to define the domains permitted for the restricted user:
- Enter **one domain or path per line**.
- Subdomains and `www.` variants are handled automatically (do not add `*.` or `https://`).
- Lines prefixed with `#` are treated as comments.
- Sub-paths are supported (e.g., `google.com/maps` or `youtube.com/@channel`).

> **Note:** Critical local routes (`localhost`, `127.0.0.1`, `file:///*`, private subnets `10.0.0.0/8`, `192.168.0.0/16`) and embedded media endpoints (e.g., `youtube.com/embed/`, `youtube-nocookie.com`) are automatically included.

### Step 3: Run the Setup
1. Right-click `Lockdown_Master.bat` and select **Run as administrator**.
2. When prompted, select the target user account from the displayed menu:
   ```text
   Select the user to RESTRICT
     1. AdminUser
     2. StudentAccount
     3. Guest
   Enter the number of the user to RESTRICT:
   ```
3. Type the number corresponding to the account and press **Enter**.
4. The script will:
   - Log off the target user if currently signed in.
   - Sweep old policies and mount the user's registry hive.
   - Deploy the URL whitelist and folder execution controls.
   - Register scheduled tasks under `C:\ProgramData\BrowserFilter\`.
   - Display a setup summary report upon completion.

---

## Verifying Deployment

1. Sign in to Windows as the restricted user.
2. Open **Microsoft Edge** or **Google Chrome**.
3. Visit `edge://policy` or `chrome://policy` and click **Reload policies**.
4. Verify that `URLBlocklist` and `URLAllowlist` are listed.
5. Attempt visiting an unlisted domain; the browser will show a block page.
6. Insert a USB flash drive containing an executable (.exe) and attempt to run it; the process will immediately terminate with an **ACCESS DENIED** dialog.

---

## Management & Diagnostic Commands

`Lockdown_Master.bat` includes built-in switches for ongoing maintenance:

```cmd
:: View live status of running tasks, policies, and active user detection
Lockdown_Master.bat status

:: Force the web filter to ON state manually
Lockdown_Master.bat on

:: Force the web filter to OFF state manually
Lockdown_Master.bat off

:: Output a comprehensive diagnostic dump of all policies and scheduled tasks
Lockdown_Master.bat diag

:: Apply policy and generate an updated summary report
Lockdown_Master.bat test

:: Run setup in verbose mode with active command echoing
Lockdown_Master.bat debug
```

---

## Removal Guide (Complete Teardown)

To completely remove the web filter, restore standard folder permissions, remove scheduled tasks, and unlock the system, use `Undo_Lockdown.bat`.

### Steps to Remove:
1. Right-click `Undo_Lockdown.bat` and choose **Run as administrator**.
2. Type `YES` when prompted to confirm removal:
   ```text
   ============================================================
     LOCKDOWN UNDO
     This will REMOVE the whole web filter and app lockdown
     from this PC (all users). Deleting the whole policy key
     clears the http/https blocklist and every allow entry.
   ============================================================

   Type YES to proceed: YES
   ```
3. The script executes an 8-stage automated cleanup:
   - **[1/8]** Stops and deletes all `WebFilter_*` and `USB_*` scheduled tasks.
   - **[2/8]** Terminates watchdog loops and notification windows.
   - **[3/8]** Clears machine-level (`HKLM`) policy entries across Chrome, Edge, Brave, and Firefox.
   - **[4/8]** Purges policies from all currently mounted user hives (`HKU`).
   - **[5/8]** Loads and purges policies from offline user profiles (`NTUSER.DAT`).
   - **[6/8]** Restores folder ACL permissions on `Downloads`, `Desktop`, `Documents`, and temp folders.
   - **[7/8]** Resets auditing configurations.
   - **[8/8]** Deletes `C:\ProgramData\BrowserFilter\` and startup links.
4. **Restart the computer** to complete teardown and ensure memory states are cleared.
