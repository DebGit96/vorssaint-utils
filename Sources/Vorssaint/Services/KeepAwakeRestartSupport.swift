// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Carries a manual keep-awake session across a deliberate restart, such as
/// an update installed by a local update script. The script writes a marker
/// (epoch seconds) and stops the app with SIGTERM; the app has saved its
/// session whenever it changed. The next launch resumes the session only
/// while the marker is fresh, so a normal quit, a crash or a relaunch much
/// later still starts with keep-awake off. Closed-lid mode is not carried:
/// switching it on is the one moment the app may ask for the password.
enum KeepAwakeRestartSupport {
    /// A marker older than this belongs to a restart that never completed.
    static let markerLifetime: TimeInterval = 10 * 60
    /// Tolerated clock skew for a marker written "in the future".
    static let markerSkew: TimeInterval = 60

    struct Snapshot: Equatable {
        /// nil = until turned off.
        var end: Date?
        /// The preset the session was started with, nil for an end time.
        var minutes: Int?

        init(end: Date?, minutes: Int?) {
            self.end = end
            self.minutes = minutes
        }

        init?(dictionary: [String: Any]?) {
            guard let dictionary, dictionary["active"] as? Bool == true else { return nil }
            end = (dictionary["end"] as? Double).map { Date(timeIntervalSince1970: $0) }
            minutes = dictionary["minutes"] as? Int
        }

        var dictionary: [String: Any] {
            var value: [String: Any] = ["active": true]
            if let end { value["end"] = end.timeIntervalSince1970 }
            if let minutes { value["minutes"] = minutes }
            return value
        }
    }

    enum Plan: Equatable {
        case none
        case resume(end: Date?, minutes: Int?)
    }

    static func plan(markerEpoch: Double, snapshot: Snapshot?, now: Date) -> Plan {
        guard markerEpoch > 0, let snapshot else { return .none }
        let age = now.timeIntervalSince1970 - markerEpoch
        guard age >= -markerSkew, age <= markerLifetime else { return .none }
        if let end = snapshot.end, end <= now { return .none }
        return .resume(end: snapshot.end, minutes: snapshot.minutes)
    }
}
