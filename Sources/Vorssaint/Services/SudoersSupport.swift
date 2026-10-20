// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Darwin
import Foundation
import Security

enum SudoersSupport {
    static var mockElevationPromptHandler: (((String?) -> Void) -> Void)?

    /// Saves the elevation password to the macOS login keychain.
    /// Uses SecItemAdd with a SecItemUpdate fallback when an entry for the account and service already exists.
    @discardableResult
    static func saveKeychainPassword(_ password: String,
                                     service: String = "vorssaint-sudo",
                                     account: String = NSUserName()) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        } else if status == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
            return updateStatus == errSecSuccess
        }
        return false
    }

    /// Removes the elevation credential from the login keychain.
    @discardableResult
    static func deleteKeychainPassword(service: String = "vorssaint-sudo",
                                       account: String = NSUserName()) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Displays a native macOS in-app dialog prompting the user for their administrator elevation password
    /// to store securely in their login Keychain, avoiding the need for manual Terminal commands.
    static func promptForElevationPassword(completion: @escaping (String?) -> Void) {
        if let mock = mockElevationPromptHandler {
            if Thread.isMainThread {
                mock(completion)
            } else {
                DispatchQueue.main.async { mock(completion) }
            }
            return
        }

        let present = {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Enterprise Privilege Elevation"
            alert.informativeText = "Closed-lid keep awake requires administrator privileges on managed Macs. Enter your administrator password to save it securely to your macOS Login Keychain so you won't have to enter it again."

            let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            input.placeholderString = "Password"
            alert.accessoryView = input

            alert.addButton(withTitle: "Save & Enable")
            alert.addButton(withTitle: "Cancel")

            alert.window.initialFirstResponder = input

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let text = input.stringValue.trimmingCharacters(in: .newlines)
                completion(text.isEmpty ? nil : text)
            } else {
                completion(nil)
            }
        }

        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async(execute: present)
        }
    }
    /// True when a `pmset -g` report lists lid sleep as disabled.
    static func sleepDisabled(inPmsetOutput output: String) -> Bool {
        output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    /// The closed-lid NOPASSWD rule, granted by uid (`#uid` user spec). A
    /// username would have to be sanitized against sudoers *and* shell
    /// metacharacters — short names on SSO-enrolled Macs can be full email
    /// addresses (#915) — while a uid interpolates as bare digits, which
    /// neither interpreter can read as anything else.
    static func clamshellRule(uid: uid_t) -> String {
        "#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
    }

    /// Known Keychain generic password service names for elevation credentials.
    static let keychainServices = ["vorssaint-sudo", "keepawake-sudo"]

    /// Fetches the elevation password from the login keychain if configured.
    /// Tries the specified account first, then falls back to searching by service name alone.
    static func keychainPassword(services: [String] = keychainServices,
                                 account: String? = NSUserName()) -> String? {
        for service in services {
            if let account = account, !account.isEmpty {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                if status == errSecSuccess, let data = item as? Data,
                   let secret = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
                   secret.count >= 4 {
                    return secret
                }
            }

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data,
               let secret = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
               secret.count >= 4 {
                return secret
            }
        }
        return nil
    }

    /// Runs a privileged command inside a pseudo-terminal (PTY), answering the sudo password
    /// prompt non-interactively using the provided credential.
    /// This bypasses PAM-level denials (such as CyberArk EPM or ServiceNow Elevate Trusted)
    /// that block non-interactive `sudo -n` while allowing standard TTY sudo.
    static func runViaPTY(command: [String],
                          password: String,
                          timeout: TimeInterval = 10.0) -> (status: Int32, output: String) {
        guard !command.isEmpty else { return (1, "no command") }
        var cArgs: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
        cArgs.append(nil)
        defer {
            for ptr in cArgs where ptr != nil { free(ptr) }
        }

        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, nil)
        if pid < 0 {
            return (-1, "forkpty failed")
        }
        if pid == 0 {
            execvp(command[0], cArgs)
            _exit(127)
        }

        var output = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var sent = false
        var childReaped = false
        var authRejected = false
        var exitStatus: Int32 = 0

        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ret = poll(&pfd, 1, 50)
            if ret > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(master, &buf, buf.count)
                if bytesRead > 0 {
                    output.append(contentsOf: buf[0..<bytesRead])
                    let str = String(decoding: output, as: UTF8.self)
                    let lower = str.lowercased()
                    let isPrompt = lower.contains("password") ||
                                   lower.contains("passcode") ||
                                   lower.contains("passwort") ||
                                   str.contains("assword")

                    if !sent && isPrompt {
                        usleep(200_000)
                        let cleanPassword = password.trimmingCharacters(in: .newlines)
                        let pwData = (cleanPassword + "\n").data(using: .utf8)!
                        pwData.withUnsafeBytes { ptr in
                            _ = write(master, ptr.baseAddress!, pwData.count)
                        }
                        sent = true
                    } else if sent && (str.contains("Sorry, try again") ||
                                       lower.contains("incorrect password") ||
                                       str.contains("Admin rights")) {
                        authRejected = true
                        kill(pid, SIGTERM)
                        break
                    }
                } else if bytesRead <= 0 {
                    break
                }
            }

            let res = waitpid(pid, &exitStatus, WNOHANG)
            if res == pid {
                childReaped = true
                break
            }
        }

        // Drain any remaining output buffered in master
        while true {
            let n = read(master, &buf, buf.count)
            if n > 0 {
                output.append(contentsOf: buf[0..<n])
            } else {
                break
            }
        }

        // Bounded wait for normal child exit before killing
        let waitDeadline = authRejected ? Date().addingTimeInterval(0.3) : deadline
        while !childReaped && Date() < waitDeadline {
            let res = waitpid(pid, &exitStatus, WNOHANG)
            if res == pid {
                childReaped = true
                break
            }
            usleep(10_000)
        }

        if !childReaped {
            kill(pid, SIGKILL)
            waitpid(pid, &exitStatus, 0)
            childReaped = true
        }

        close(master)

        let rc: Int32
        if authRejected {
            rc = 1
        } else if (exitStatus & 0x7F) == 0 {
            rc = (exitStatus >> 8) & 0xFF
        } else {
            rc = 1
        }
        return (rc, String(decoding: output, as: UTF8.self))
    }
}
