// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreServices
import Darwin
import os

enum Shell {
    /// A command that stops answering must not keep a thread forever. Nothing
    /// here asks a question that is worth more than a few seconds, and a tool
    /// waiting on a damaged disk or a share that went away can wait for good.
    static let defaultTimeout: TimeInterval = 5

    @discardableResult
    static func run(_ path: String,
                    _ args: [String],
                    timeout: TimeInterval = defaultTimeout,
                    maxOutputBytes: Int = 4 * 1024 * 1024)
        -> (status: Int32, output: String) {
        let result = BoundedProcessRunner.run(path, args,
                                              timeout: timeout,
                                              maxOutputBytes: maxOutputBytes)
        return (result.status, String(decoding: result.output, as: UTF8.self))
    }
}

/// Runs a command with administrator privileges (system password prompt).
enum AdminShell {
    // Vorssaint is a menu-bar agent (LSUIElement), so it is rarely the active
    // app. SecurityAgent attaches its password dialog to the requesting process;
    // when that process is an inactive agent the dialog can open behind the
    // frontmost app and read as "no prompt appeared". Bringing the app forward
    // first — exactly what onboarding and the Dock Preview intro already do for
    // their own windows — makes the dialog surface in focus.
    //
    // `prompting` serializes the request: a second one while a dialog is already
    // up returns false instead of stacking another SecurityAgent dialog (what a
    // frustrated retry used to do, and what was linked to the instability in
    // issue #63). Every caller already treats false as "permission not granted".
    private static let promptLock = NSLock()
    private static var prompting = false

    private enum RequestOrigin {
        case systemScript
        case signedApp
    }

    static func runSync(_ command: String, prompt: String) -> Bool {
        runSync(command, prompt: prompt, origin: .systemScript)
    }

    private static func runSync(_ command: String, prompt: String, origin: RequestOrigin) -> Bool {
        promptLock.lock()
        if prompting {
            promptLock.unlock()
            return false
        }
        prompting = true
        promptLock.unlock()
        defer {
            promptLock.lock()
            prompting = false
            promptLock.unlock()
        }

        bringAppToFront()
        let source = appleScriptSource(command: command, prompt: prompt)
        switch origin {
        case .systemScript:
            // A person typing a password is not a stuck command. Keep the
            // established bound without rushing a prompt that is being read.
            return Shell.run("/usr/bin/osascript", ["-e", source], timeout: 600).status == 0
        case .signedApp:
            // NSAppleScript is main-thread-only. The updater's elevated shell
            // detaches immediately after approval, so this wait covers only the
            // system authorization interaction.
            return DispatchQueue.main.sync {
                AppleScriptRunner.run(source).ok
            }
        }
    }

    static func run(_ command: String, prompt: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(runSync(command, prompt: prompt))
        }
    }

    /// Runs the administrator request inside this signed process so system
    /// policy can identify the app that initiated it. Reserved for the updater;
    /// other administrative tools retain their bounded subprocess behavior.
    static func runInProcess(_ command: String, prompt: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(runSync(command, prompt: prompt, origin: .signedApp))
        }
    }

    /// Brings the app forward so the administrator dialog opens in focus. Safe
    /// from any thread: hops to the main thread when it is not already on it.
    private static func bringAppToFront() {
        if Thread.isMainThread {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            DispatchQueue.main.sync {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Thread.sleep(forTimeInterval: 0.12)
    }

    static func appleScriptSource(command: String, prompt: String) -> String {
        "do shell script \(appleScriptString(command)) with administrator privileges with prompt \(appleScriptString(prompt))"
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// NOPASSWD rule restricted to `pmset disablesleep 0/1`, so closed-lid mode can
/// toggle without asking for the administrator password every time.
/// The password is asked once, when installing (or removing) the rule.
enum Sudoers {
    static let rulePath = "/etc/sudoers.d/vorssaint-clamshell"
    // Rule files written under earlier names; removed whenever the rule is
    // (re)installed or removed, so the closed-lid permission migrates without an
    // extra password prompt.
    private static let legacyRulePaths = [
        "/etc/sudoers.d/vorssaint-utils-clamshell",
        "/etc/sudoers.d/vorss-clamshell",
    ]

    /// Serializes native writes and read/reapply probes. Authorization runs
    /// separately with probes suspended, so a probe cannot resurrect a stale
    /// "1" after a restore cleared it and leave lid sleep off without a marker.
    private static let sleepStateQueue = DispatchQueue(label: "com.vorssaint.utils.pmset-state")
    // Authorization runs outside this queue so quitting never waits for a
    // password prompt. Probes must not reapply a stale state during that off.
    private static var sleepStateProbeSuspensions = 0

    /// Proves the passwordless path by running it: re-applying the current
    /// SleepDisabled state through `sudo -n` changes nothing on the system and
    /// exercises the exact call the feature makes. Listing checks (`sudo -l`)
    /// reported the rule as ready on Macs where the real call still asked for
    /// a password, which put every toggle behind a prompt (issue #269).
    static func isConfigured() -> Bool {
        sleepStateQueue.sync {
            guard sleepStateProbeSuspensions == 0 else { return false }
            let report = Shell.run("/usr/bin/pmset", ["-g"])
            guard report.status == 0 else { return false }
            return pmsetDisableSleepOnQueue(SudoersSupport.sleepDisabled(inPmsetOutput: report.output))
        }
    }

    static var ruleFileDetector: (() -> Bool)?
    static var ruleFilesPresent: Bool {
        ruleFileDetector?() ?? ([rulePath] + legacyRulePaths).contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Elevation credential (PTY fallback)
    //
    // The password the PTY fallback types into `sudo` is held in memory while
    // closed-lid mode is on. Launch, status probes, timers and quit only ever
    // use that copy, so none of them can raise a keychain prompt or a password
    // dialog. The keychain is read, and the dialog shown, only by `install`
    // right after the user switches closed-lid mode on.

    private static let credentialLock = NSLock()
    private static var heldCredential: String?
    private static var credentialPermitExpiry: Date?
    /// Set when sudo rejected the stored copy, so the next setup asks for the
    /// password instead of trying the stale one again (each failure counts
    /// toward an account lockout).
    private static var storedCredentialRejected = false
    /// How long switching closed-lid mode on allows one credential request.
    static var credentialPermitLifetime: TimeInterval = 60

    private static func withCredentialLock<T>(_ body: () -> T) -> T {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        return body()
    }

    static var holdsCredential: Bool { withCredentialLock { heldCredential != nil } }

    /// Called when the user switches closed-lid mode on: the next `install`
    /// within `credentialPermitLifetime` may read the keychain or show the dialog.
    static func permitCredentialRequest() {
        withCredentialLock { credentialPermitExpiry = Date().addingTimeInterval(credentialPermitLifetime) }
    }

    private static func consumeCredentialPermit() -> Bool {
        withCredentialLock {
            defer { credentialPermitExpiry = nil }
            guard let expiry = credentialPermitExpiry else { return false }
            return expiry > Date()
        }
    }

    private static func holdCredential(_ password: String) {
        withCredentialLock {
            heldCredential = password
            storedCredentialRejected = false
        }
    }

    /// Drops the in-memory password once every write already queued, such as
    /// the restore that switching closed-lid mode off just requested, has run.
    static func releaseCredentialAfterQueuedWrites() {
        sleepStateQueue.async { releaseCredential() }
    }

    private static func releaseCredential() {
        withCredentialLock { heldCredential = nil }
    }

    /// Runs the PTY fallback with `password` (through the test seam when one
    /// is installed, so tests never type a fake password into the real sudo).
    private static func runPrivileged(_ command: [String], password: String) -> (status: Int32, output: String) {
        SudoersSupport.verificationRunner?(command, password)
            ?? SudoersSupport.runViaPTY(command: command, password: password)
    }

    /// Re-applies the current SleepDisabled state with `password`, which
    /// changes nothing on the system and proves the credential works.
    private static func credentialWorks(_ password: String) -> Bool {
        let report = Shell.run("/usr/bin/pmset", ["-g"])
        let sleepDisabled = report.status == 0 && SudoersSupport.sleepDisabled(inPmsetOutput: report.output)
        let command = ["/usr/bin/sudo", "/usr/bin/pmset", "disablesleep", sleepDisabled ? "1" : "0"]
        return runPrivileged(command, password: password).status == 0
    }

    static func install(completion: @escaping (Bool) -> Void) {
        if isConfigured() {
            completion(true)
            return
        }
        // Anything but the user switching closed-lid mode on (a new session,
        // a screen unlock, a retry) ends here without any prompt.
        guard consumeCredentialPermit() else {
            sudoersLog.notice("closed-lid setup needs the elevation password; switch closed-lid mode on to provide it")
            completion(false)
            return
        }

        // The stored copy first: one keychain read, which macOS may confirm
        // with its own prompt for a rebuilt app. Verifying it runs off the
        // calling thread; the dialog is only shown when it is missing or refused.
        let skipStored = withCredentialLock { storedCredentialRejected }
        if !skipStored, let stored = SudoersSupport.keychainPassword() {
            DispatchQueue.global(qos: .userInitiated).async {
                if credentialWorks(stored) {
                    holdCredential(stored)
                    SudoersSupport.removeLegacyKeychainItems()
                    completion(true)
                    return
                }
                withCredentialLock { storedCredentialRejected = true }
                askForCredential(completion: completion)
            }
            return
        }
        askForCredential(completion: completion)
    }

    /// Shows the in-app password dialog; nothing is stored until sudo accepts the answer.
    private static func askForCredential(completion: @escaping (Bool) -> Void) {
        SudoersSupport.promptForElevationPassword { password in
            guard let password, !password.isEmpty else {
                completion(false)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard credentialWorks(password) else {
                    completion(false)
                    return
                }
                holdCredential(password)
                if SudoersSupport.saveKeychainPassword(password) {
                    SudoersSupport.removeLegacyKeychainItems()
                }
                completion(true)
            }
        }
    }

    static func remove(completion: @escaping (Bool) -> Void) {
        releaseCredential()
        SudoersSupport.deleteKeychainPassword()
        SudoersSupport.removeLegacyKeychainItems()
        guard ruleFilesPresent else {
            completion(true)
            return
        }
        // Also removes the rules left behind by earlier app names.
        let all = ([rulePath] + legacyRulePaths).joined(separator: " ")
        AdminShell.run("rm -f \(all)",
                       prompt: L10n.shared.s.adminPromptSudoersRemove) { ok in
            completion(ok)
        }
    }

    /// Toggles sleep through the password-free path. Fails silently
    /// (returns false) when the rule is not installed.
    @discardableResult
    static func pmsetDisableSleep(_ on: Bool) -> Bool {
        sleepStateQueue.sync { pmsetDisableSleepOnQueue(on) }
    }

    /// Queues asynchronous writes directly in request order. Completions
    /// must not wait for the main thread or for administrator authorization.
    static func pmsetDisableSleep(_ on: Bool, completion: @escaping (Bool) -> Void) {
        sleepStateQueue.async {
            completion(pmsetDisableSleepOnQueue(on))
        }
    }

    /// Completes earlier probes before authorization can restore sleep and
    /// suspends later probes until it finishes. The queue remains free for a
    /// silent restore during quit; the main-thread guard cancels stale prompts.
    static func restoreSleepWithAuthorization(prompt: String,
                                              shouldProceed: @escaping () -> Bool,
                                              completion: @escaping (Bool) -> Void) {
        sleepStateQueue.async {
            sleepStateProbeSuspensions += 1
            let finish: (Bool) -> Void = { ok in
                sleepStateQueue.async {
                    sleepStateProbeSuspensions -= 1
                    completion(ok)
                }
            }
            // A failed enable may never have set the override. Once probes
            // are suspended, a confirmed off needs no further authorization.
            let report = Shell.run("/usr/bin/pmset", ["-g"])
            if report.status == 0, !SudoersSupport.sleepDisabled(inPmsetOutput: report.output) {
                finish(true)
                return
            }
            DispatchQueue.main.async {
                guard shouldProceed() else {
                    finish(false)
                    return
                }
                AdminShell.run("pmset disablesleep 0", prompt: prompt, completion: finish)
            }
        }
    }

    private static let sudoersLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "vorssaint",
                                           category: "sudoers")

    private static func pmsetDisableSleepOnQueue(_ on: Bool) -> Bool {
        let standardResult = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", on ? "1" : "0"])
        if standardResult.status == 0 {
            return true
        }

        sudoersLog.info("sudo -n pmset disablesleep \(on ? "1" : "0") failed with status \(standardResult.status)")

        // On corporate-managed Macs (CyberArk EPM / ServiceNow Elevate Trusted), non-interactive
        // sudo is denied at PAM level (/private/cyberark/CyberArkEPMPAM) despite installed rules.
        // Fall back to bare sudo in a pseudo-terminal (PTY) with the password held in memory.
        // This never reads the keychain: see "Elevation credential" above.
        if let password = withCredentialLock({ heldCredential }) {
            let ptyResult = runPrivileged(["/usr/bin/sudo", "/usr/bin/pmset", "disablesleep", on ? "1" : "0"],
                                          password: password)
            if ptyResult.status == 0 {
                sudoersLog.info("PTY elevation succeeded for pmset disablesleep \(on ? "1" : "0")")
                return true
            }
            if ptyResult.status == SudoersSupport.passwordRejectedStatus {
                // Never retry a rejected password automatically.
                withCredentialLock {
                    heldCredential = nil
                    storedCredentialRejected = true
                }
                sudoersLog.error("sudo rejected the held elevation password; closed-lid mode needs it again")
            } else {
                sudoersLog.error("PTY elevation failed with status \(ptyResult.status)")
            }
            return false
        }

        sudoersLog.notice("no elevation password in memory; switching closed-lid mode on asks for it")
        return false
    }
}

/// Sends Apple Events to another app IN-PROCESS (via NSAppleScript) instead of
/// spawning `osascript`. The Automation consent is then attributed to THIS app —
/// so it stays granted across updates, is re-requested if it was lost, and the
/// first-run consent prompt is never killed by a watchdog. It is the same
/// per-target Automation permission the features already required; nothing new is
/// requested. Call these OFF the main thread, so a slow target never blocks the
/// UI or the event taps (the calls block their thread until the target replies).
enum AppleScriptRunner {
    /// True when this app may script `bundleID`. Undetermined → shows the system
    /// prompt (attributed to this app); granted → returns at once; denied →
    /// false without nagging.
    @discardableResult
    static func consentToAutomate(bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let created = bundleID.withCString { ptr in
            AECreateDesc(typeApplicationBundleID, ptr, bundleID.utf8.count, &target)
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true) == noErr
    }

    /// Runs the AppleScript in this process. Returns whether it succeeded and the
    /// result string (or the error message on failure). Sending the event in
    /// process itself triggers the Automation prompt when consent is undetermined.
    @discardableResult
    static func run(_ source: String) -> (ok: Bool, output: String) {
        let result = runDetailed(source)
        return (result.ok, result.ok ? result.output : result.message)
    }

    /// Same as `run`, keeping the AppleScript error number so callers can tell
    /// a declined Automation consent (-1743/-1744) apart from a real failure.
    @discardableResult
    static func runDetailed(_ source: String) -> (ok: Bool, errorNumber: Int?, message: String, output: String) {
        guard let script = NSAppleScript(source: source) else { return (false, nil, "", "") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return (false,
                    error[NSAppleScript.errorNumber] as? Int,
                    (error[NSAppleScript.errorMessage] as? String) ?? "",
                    "")
        }
        return (true, nil, "", result.stringValue ?? "")
    }

    /// Escapes a value for embedding inside an AppleScript double-quoted string.
    static func literal(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
