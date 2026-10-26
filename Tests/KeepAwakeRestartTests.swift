// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// A deliberate restart (an update installed by a local script) resumes the
/// manual keep-awake session with the time it had left, and nothing else:
/// closed-lid mode starts off, and no restore may wait for a password.
enum KeepAwakeRestartTests {
    private typealias Support = KeepAwakeRestartSupport

    static func run(expect: (Bool, String) -> Void) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let marker = now.timeIntervalSince1970 - 30
        let timed = Support.Snapshot(end: now.addingTimeInterval(3600), minutes: 120)
        let indefinite = Support.Snapshot(end: nil, minutes: nil)

        expect(Support.plan(markerEpoch: marker, snapshot: timed, now: now)
               == .resume(end: now.addingTimeInterval(3600), minutes: 120),
               "a fresh restart marker resumes a timed session with its original end and preset")
        expect(Support.plan(markerEpoch: marker, snapshot: indefinite, now: now) == .resume(end: nil, minutes: nil),
               "a fresh restart marker resumes a session that runs until turned off")
        expect(Support.plan(markerEpoch: 0, snapshot: timed, now: now) == .none,
               "without a marker (a normal quit or a crash) nothing resumes")
        expect(Support.plan(markerEpoch: now.timeIntervalSince1970 - Support.markerLifetime - 1,
                            snapshot: timed, now: now) == .none,
               "a marker from a restart that never completed is ignored")
        expect(Support.plan(markerEpoch: now.timeIntervalSince1970 + Support.markerSkew + 1,
                            snapshot: timed, now: now) == .none,
               "a marker far in the future is ignored")
        expect(Support.plan(markerEpoch: marker, snapshot: nil, now: now) == .none,
               "a marker without a saved session resumes nothing")
        expect(Support.plan(markerEpoch: marker, snapshot: Support.Snapshot(end: now, minutes: 30), now: now) == .none,
               "a session whose end time has passed is not resumed")

        expect(Support.Snapshot(dictionary: timed.dictionary) == timed
               && Support.Snapshot(dictionary: indefinite.dictionary) == indefinite,
               "a saved session reads back unchanged")
        expect(Support.Snapshot(dictionary: nil) == nil && Support.Snapshot(dictionary: ["end": 1.0]) == nil,
               "a missing or malformed record is no session")

        // The wiring lives in files an upstream sync can rewrite, so its
        // shape is pinned here.
        func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        let delegate = source("Sources/Vorssaint/App/AppDelegate.swift")
        expect(delegate.contains("DispatchSource.makeSignalSource(signal: SIGTERM")
               && delegate.contains("termination.setEventHandler { NSApp.terminate(nil) }"),
               "SIGTERM quits through NSApp.terminate so keep-awake teardown runs")
        let resumeCall = delegate.range(of: "resumeAfterDeliberateRestartIfNeeded()")
        let autoStartCall = delegate.range(of: "activateOnLaunchIfNeeded()")
        expect(resumeCall != nil && autoStartCall != nil && resumeCall!.lowerBound < autoStartCall!.lowerBound,
               "launch resumes a restarted session before the start-at-launch preference")

        let manager = source("Sources/Vorssaint/Services/KeepAwakeManager.swift")
        let initBody = manager.range(of: "    private init() {").map { manager[$0.lowerBound...].prefix(900) } ?? ""
        expect(initBody.contains("clamshellPreferred = false")
               && !manager.contains("clamshellPreferred = UserDefaults.standard.bool(forKey: DefaultsKey.clamshellPreferred)"),
               "closed-lid mode starts off at every launch")
        expect(source("Sources/Vorssaint/Services/ShellSupport.swift").contains("static var allowsAuthorizationPrompts = false"),
               "the app ships with restore authorization prompts off")
        expect(source("Sources/Vorssaint/App/StatusItemController.swift").contains("clamshellOverrideStuck"),
               "the menu bar badge also marks an override left on")
    }
}
