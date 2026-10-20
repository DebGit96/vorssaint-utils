# RFC: Enterprise Privilege Elevation for Clamshell Keep-Awake

- **Author**: Debangshu Banerjee (@DebGit96)
- **Status**: Proposed / Discussion
- **Feature Area**: Energy and display (`Sources/Vorssaint/Services/KeepAwakeManager.swift`, `Sources/Vorssaint/Services/ShellSupport.swift`)
- **Applies to**: macOS 14+ on Apple Silicon (Enterprise / Corporate-managed MDM environments)

---

## 1. Summary

On corporate-managed Macs running Endpoint Privilege Management (EPM) tools—such as CyberArk EPM or ServiceNow Elevate Trusted—Vorssaint's "Keep awake with lid closed" fails immediately when toggled on. 

While Vorssaint successfully creates a valid, syntax-checked sudoers rule at `/etc/sudoers.d/vorssaint-clamshell`, non-interactive execution (`sudo -n /usr/bin/pmset disablesleep 1`) is categorically rejected at the PAM layer by enterprise EPM modules.

This RFC outlines the root cause of this failure and presents two architectural options:
1. **Preferred long-term architecture**: A native privileged helper daemon via `SMAppService.daemon` (mirroring Vorssaint's existing `com.vorssaint.utils.fan-control` helper).
2. **Immediate, zero-daemon fallback**: A lightweight Keychain-backed pseudo-terminal (PTY) runner that activates only when `sudo -n` returns an authentication failure.

---

## 2. Motivation and Problem Analysis

### Current Implementation
To enable closed-lid keep-awake without repeatedly prompting the user for an administrator password, Vorssaint installs a scoped sudoers drop-in file:
```text
# /etc/sudoers.d/vorssaint-clamshell
#<uid> ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0
```
When toggling the preference or applying the sleep policy, `Sudoers.isConfigured()` and `Sudoers.pmsetDisableSleepOnQueue(_:)` execute:
```swift
Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", on ? "1" : "0"])
```
The `-n` flag (`--non-interactive`) tells `sudo` to fail immediately rather than prompting for a password if authorization cannot be satisfied without user input.

### Failure Mode on Corporate / MDM Macs
In enterprise environments with Endpoint Privilege Management:
1. MDM / security tooling injects a PAM authentication module into `/etc/pam.d/sudo`:
   ```text
   # /etc/pam.d/sudo
   auth       sufficient     /private/cyberark/CyberArkEPMPAM
   auth       include        sudo_local
   auth       sufficient     pam_smartcard.so
   auth       required       pam_opendirectory.so
   account    required       pam_permit.so
   password   required       pam_deny.so
   session    required       pam_permit.so
   ```
2. When `/usr/bin/sudo -n` executes, PAM passes control to the EPM PAM module.
3. Corporate EPM policies categorically disallow non-interactive privilege elevation or refuse to honor `NOPASSWD` without an interactive terminal context. Even though `/usr/bin/visudo -c -f /etc/sudoers.d/vorssaint-clamshell` validates the file syntax as correct, `sudo -n` exits with code 1 (`sudo: a password is required`).
4. `Sudoers.isConfigured()` returns `false`, causing `prepareClamshellPreference()` to mark the setup as failed and turn off the toggle. The user sees:
   > *"Couldn’t turn on closed-lid mode. Try again."*

---

## 3. Proposed Solutions

### Solution A: Native Privileged Helper Tool via `SMAppService.daemon` (Preferred Long-Term)

Vorssaint already incorporates a privileged launch daemon pattern in `Sources/FanControlHelper` registered via `SMAppService.daemon(plistName: FanControlIdentifiers.plistName)` and communicating over `NSXPCConnection` (`com.vorssaint.utils.fan-control`).

#### Design
- Either extend the existing helper target or introduce a lightweight privileged helper (`com.vorssaint.utils.power-helper` or unified `com.vorssaint.utils.helper`).
- The daemon runs with root privileges managed by macOS `launchd` via `SMAppService.daemon`.
- Vorssaint connects over Mach service XPC and requests power operations (e.g. `setSleepDisabled(Bool)`).
- The helper validates code-signing requirements of the connecting client via `SecCodeCheckValidity`.

#### Advantages
- **Eliminates `sudo` entirely**: No file writes to `/etc/sudoers.d/`, no `visudo` calls, and no PAM interference.
- **Modern Apple standard**: Fully conforms to macOS 13+ App Management & SMAppService guidelines.
- **Enterprise transparent**: EPM and PAM do not intercept launchd daemons.

#### Considerations
- Adds another launch daemon / Mach service definition.
- Requires user approval in *System Settings > General > Login Items & Extensions* (or managed silently via MDM configuration profile `com.apple.servicemanagement`).

---

### Solution B: Keychain-Backed PTY Runner (Immediate Fallback)

For users who want closed-lid keep-awake without waiting for or managing launch daemons, a zero-daemon fallback can be integrated directly into `SudoersSupport.swift`.

This approach was prototyped and proven in the standalone `keepawake-cli` utility and verified on corporate-managed macOS 15 Apple Silicon systems.

#### How It Works
1. `pmsetDisableSleepOnQueue` first attempts the normal `sudo -n /usr/bin/pmset disablesleep <value>`. On standard personal Macs, this succeeds immediately with zero overhead.
2. If `sudo -n` exits non-zero (indicating non-interactive elevation is denied), it checks if an elevation credential exists in the user's macOS login Keychain for service `vorssaint-sudo` (or fallback `keepawake-sudo`).
3. If a credential exists, it executes bare `/usr/bin/sudo /usr/bin/pmset disablesleep <value>` inside a pseudo-terminal (allocated via native Darwin `forkpty`).
4. Because bare `sudo` executes inside a genuine PTY with a controlling terminal (`/dev/tty`):
   - The EPM PAM module allows the invocation as a valid interactive terminal session.
   - Sudo issues its standard password prompt.
   - The runner detects the prompt marker, pauses briefly (200ms) for sudo to disable terminal echo, and writes the password to the master FD followed by `\n`.
   - The elevation succeeds with exit code 0.

#### Security & Quality Properties
- **No plaintext storage**: The secret resides in the user's macOS Login Keychain, accessible only within the user's logged-in session.
- **No process leak**: The password is never passed via `argv` (invisible in `ps`) and never written to disk or logs.
- **Pure fallback**: Only triggers if `sudo -n` fails; zero effect on standard consumer machines.
- **Zero external dependencies**: Implemented using pure Darwin APIs (`forkpty`, `poll`, `read`, `write`, `fcntl`) and `Security.framework` (`SecItemCopyMatching`).

#### User Onboarding & Setup

Vorssaint supports two onboarding paths for enterprise credentials:

1. **Native In-App GUI Prompt (Primary)**:
   - When the user toggles closed-lid keep-awake ON and `sudo -n` is blocked (or no valid credential exists), Vorssaint presents a native AppKit modal dialog (`NSAlert` with `NSSecureTextField`).
   - The dialog informs the user that enterprise privilege elevation is required on managed Macs and will be saved securely to their macOS Login Keychain so they don't have to enter it again.
   - Buttons: **Save & Enable** and **Cancel**.
   - Upon clicking "Save & Enable", Vorssaint stores the password using `SecItemAdd` (with automatic `SecItemUpdate` fallback on existing items), verifies execution in a background Darwin PTY runner (`runViaPTY`), and keeps the toggle ON.
   - If canceled or if verification fails, the toggle cleanly reverts to OFF with zero terminal interaction required.

2. **Manual Terminal Provisioning (Optional / Headless)**:
   - Users or MDM administrators can also pre-seed or manage the login Keychain item via standard CLI:
     ```sh
     security add-generic-password -a "$USER" -s vorssaint-sudo -w -U
     ```

---

## 4. Prototype Validation & Evidence

The fallback and native in-app onboarding flow have been tested on macOS 15 (Apple Silicon) in an enterprise-managed machine with CyberArk EPM and ServiceNow Elevate PAM:
- Prior to fallback: `sudo -n /usr/bin/pmset -g` exits with code 1 (`sudo: a password is required`), preventing clamshell mode from activating.
- With Keychain PTY runner: `/usr/bin/sudo /usr/bin/pmset disablesleep 1` exits with code 0; `pmset -g` confirms `SleepDisabled 1`.
- Restoring sleep: `/usr/bin/sudo /usr/bin/pmset disablesleep 0` exits with code 0; `pmset -g` confirms `SleepDisabled 0`.
- Native In-App GUI prompt: Seamlessly saves and updates credentials via `saveKeychainPassword` with duplicate handling, verifies elevation, and cleanly reverts on cancellation.
- All repository test suites pass without warnings:
  ```text
  ./build.sh --test-suite=keep-awake  -> 151 checks OK
  ./build.sh --test-suite=preferences -> 128 checks OK
  ./build.sh --test                   -> 112972 checks OK
  ./build/VorssaintDeveloper --selftest -> SELFTEST OK
  ```

---

## 5. Questions for Maintainers

1. **Direction**: Would maintainers prefer migrating privileged tasks to an expanded `SMAppService.daemon` (alongside or combined with `fan-control-helper`), or does a zero-daemon Keychain PTY fallback provide an ideal, minimally invasive bridge for enterprise users?
2. **Settings Guidance**: With native in-app onboarding implemented, users are automatically prompted upon toggling clamshell keep-awake; no manual terminal setup is necessary.
3. **Scope**: Should this be split into an immediate PR for the PTY fallback and in-app prompt, followed by a separate PR for the long-term `SMAppService` power daemon?
