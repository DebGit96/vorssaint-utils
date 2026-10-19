// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation
import Security

enum SudoersSupport {
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
    static func keychainPassword(services: [String] = keychainServices,
                                 account: String = NSUserName()) -> String? {
        for service in services {
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
            execv(command[0], cArgs)
            _exit(127)
        }

        var output = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var sent = false

        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let deadline = Date().addingTimeInterval(timeout)
        var exitStatus: Int32 = 0

        while Date() < deadline {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ret = poll(&pfd, 1, 100)
            if ret > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(master, &buf, buf.count)
                if bytesRead > 0 {
                    output.append(contentsOf: buf[0..<bytesRead])
                    let str = String(decoding: output, as: UTF8.self)
                    if !sent && str.lowercased().contains("password") {
                        usleep(200_000)
                        let pwData = (password + "\n").data(using: .utf8)!
                        pwData.withUnsafeBytes { ptr in
                            _ = write(master, ptr.baseAddress!, pwData.count)
                        }
                        sent = true
                    }
                } else if bytesRead <= 0 {
                    break
                }
            }
            let res = waitpid(pid, &exitStatus, WNOHANG)
            if res == pid { break }
        }

        if waitpid(pid, &exitStatus, WNOHANG) == 0 {
            kill(pid, SIGKILL)
            waitpid(pid, &exitStatus, 0)
        }

        close(master)
        let rc: Int32
        if (exitStatus & 0x7F) == 0 {
            rc = (exitStatus >> 8) & 0xFF
        } else {
            rc = 1
        }
        return (rc, String(decoding: output, as: UTF8.self))
    }
}
