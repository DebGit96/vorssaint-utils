// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import Combine
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import VMStatisticsCompat

enum PreferencesFeatureTests {
    static func run(_ suite: TestSuite) {
        // MARK: Registered defaults

        let registeredDefaults = Defaults.registeredDefaults
        suite.expect(registeredDefaults[DefaultsKey.monitorMemoryMetric] as? String == "used",
               "monitor memory metric defaults to memory used")
        suite.expect(Defaults.sanitizedMonitorMemoryMetric("app") == "app",
               "app is an allowed memory metric")
        suite.expect(Defaults.sanitizedMonitorMemoryMetric("bogus") == "used",
               "unknown memory metric values fall back to used")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.monitorMemoryMetric),
               "monitor memory metric is included in settings backups")
        suite.expect(!SettingsBackupSupport.exportKeys().contains(DefaultsKey.recorderSaveFolder),
               "a chosen recording save folder is authority on one Mac and must not travel in a settings backup")
        suite.expect(!SettingsBackupSupport.exportKeys().contains(DefaultsKey.screenshotSaveFolder),
               "a chosen screenshot save folder is authority on one Mac and must not travel in a settings backup")
        suite.expect(!SettingsBackupSupport.exportKeys().contains(DefaultsKey.musicBlockReplacementPath),
               "a chosen replacement app bundle path is authority on one Mac and must not travel in a settings backup")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.screenshotSaveSubfolder),
               "a screenshot subfolder name is a pattern rather than a path, so it still follows settings backups")
        suite.expect(!SettingsBackupSupport.exportKeys().contains(DefaultsKey.commandBarFileScopes)
            && !SettingsBackupSupport.exportKeys().contains(DefaultsKey.whatsAppOrganizerDestinationPath)
            && !SettingsBackupSupport.exportKeys().contains(DefaultsKey.notchDownloadsFolderBookmark)
            && !SettingsBackupSupport.exportKeys().contains(DefaultsKey.wallpaperOwnBookmarks)
            && !SettingsBackupSupport.exportKeys().contains(DefaultsKey.mediaImageWatermarkLogoPath),
               "every chosen folder already excluded from backups stays excluded")
        suite.expect(!SettingsBackupSupport.keysToClear(whenImporting: [:]).contains(DefaultsKey.recorderSaveFolder)
            && !SettingsBackupSupport.keysToClear(whenImporting: [:]).contains(DefaultsKey.screenshotSaveFolder)
            && !SettingsBackupSupport.keysToClear(whenImporting: [:]).contains(DefaultsKey.musicBlockReplacementPath),
               "importing a backup never clears the Mac's own chosen save folders, because the clear set follows the export set")
        suite.expect(registeredDefaults[DefaultsKey.appearance] as? String == AppAppearance.system.rawValue,
               "the app follows the system appearance until the user picks a side")
        suite.expect(registeredDefaults[DefaultsKey.liquidGlassEnabled] as? Bool == false,
               "liquid glass in other windows is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.notchLiquidGlassEnabled] as? Bool == false,
               "liquid glass in Dynamic Island is opt-in")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.liquidGlassEnabled),
               "liquid glass in other windows follows settings backups")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.notchLiquidGlassEnabled),
               "liquid glass in Dynamic Island follows settings backups")
        suite.expect(SettingsBackupSupport.keysToClear(whenImporting: [
            DefaultsKey.notchEnabled: true
        ]).contains(DefaultsKey.notchLiquidGlassEnabled)
            && !SettingsBackupSupport.keysToClear(whenImporting: [:])
                .contains(DefaultsKey.notchLiquidGlassEnabled),
               "old backups with island settings can migrate their glass choice, while older backups keep the local choice")
        let glassDomain = "vorss.tests.glass-migration.\(UUID().uuidString)"
        let glassDefaults = UserDefaults(suiteName: glassDomain)!
        defer { glassDefaults.removePersistentDomain(forName: glassDomain) }
        Defaults.migrateLiquidGlassIsland(in: glassDefaults, domainName: glassDomain)
        suite.expect(glassDefaults.persistentDomain(forName: glassDomain)?[
            DefaultsKey.notchLiquidGlassEnabled] as? Bool == false,
               "a new installation saves the island glass choice as off")
        glassDefaults.set(true, forKey: DefaultsKey.liquidGlassEnabled)
        Defaults.migrateLiquidGlassIsland(in: glassDefaults, domainName: glassDomain)
        suite.expect(!glassDefaults.bool(forKey: DefaultsKey.notchLiquidGlassEnabled),
               "turning on glass for other windows after the first launch leaves the island off")
        glassDefaults.removeObject(forKey: DefaultsKey.notchLiquidGlassEnabled)
        Defaults.migrateLiquidGlassIsland(in: glassDefaults, domainName: glassDomain)
        suite.expect(glassDefaults.bool(forKey: DefaultsKey.notchLiquidGlassEnabled),
               "an existing glass preference is copied to Dynamic Island")
        glassDefaults.set(false, forKey: DefaultsKey.liquidGlassEnabled)
        Defaults.migrateLiquidGlassIsland(in: glassDefaults, domainName: glassDomain)
        suite.expect(glassDefaults.bool(forKey: DefaultsKey.notchLiquidGlassEnabled),
               "changing other windows does not change an already migrated island")
        glassDefaults.set(false, forKey: DefaultsKey.notchLiquidGlassEnabled)
        glassDefaults.set(true, forKey: DefaultsKey.liquidGlassEnabled)
        Defaults.migrateLiquidGlassIsland(in: glassDefaults, domainName: glassDomain)
        suite.expect(!glassDefaults.bool(forKey: DefaultsKey.notchLiquidGlassEnabled),
               "an explicit island choice survives later launches")
        let companionDomain = "vorss.tests.companion-beta.\(UUID().uuidString)"
        let companionDefaults = UserDefaults(suiteName: companionDomain)!
        defer { companionDefaults.removePersistentDomain(forName: companionDomain) }
        // Setup writes every feature's availability, the companion's as off.
        companionDefaults.set(true, forKey: AppFeature.commandBar.availabilityKey)
        companionDefaults.set(false, forKey: AppFeature.notchMascot.availabilityKey)
        companionDefaults.set(false, forKey: AppFeature.notch.availabilityKey)
        Defaults.installCompanionForBetaCommandBar(in: companionDefaults, isBeta: true)
        let waitsForSetup = !companionDefaults.bool(forKey: AppFeature.notchMascot.availabilityKey)
        companionDefaults.set(true, forKey: DefaultsKey.hasOnboarded)
        Defaults.installCompanionForBetaCommandBar(in: companionDefaults, isBeta: false)
        let stableUntouched = !companionDefaults.bool(forKey: AppFeature.notchMascot.availabilityKey)
        Defaults.installCompanionForBetaCommandBar(in: companionDefaults, isBeta: true)
        let noIsland = !companionDefaults.bool(forKey: AppFeature.notchMascot.availabilityKey)
            && !companionDefaults.bool(forKey: DefaultsKey.notchMascotBetaInstalled)
        companionDefaults.set(true, forKey: AppFeature.notch.availabilityKey)
        Defaults.installCompanionForBetaCommandBar(in: companionDefaults, isBeta: true)
        let installed = companionDefaults.bool(forKey: AppFeature.notchMascot.availabilityKey)
            && companionDefaults.bool(forKey: DefaultsKey.notchMascotEnabled)
        companionDefaults.set(false, forKey: AppFeature.notchMascot.availabilityKey)
        Defaults.installCompanionForBetaCommandBar(in: companionDefaults, isBeta: true)
        let keptOut = !companionDefaults.bool(forKey: AppFeature.notchMascot.availabilityKey)
        companionDefaults.removeObject(forKey: DefaultsKey.notchMascotBetaInstalled)
        companionDefaults.set(false, forKey: AppFeature.commandBar.availabilityKey)
        let noCommandBar = !Defaults.installsCompanionForBeta(in: companionDefaults, isBeta: true)
        suite.expect(waitsForSetup && stableUntouched && noIsland && installed && keptOut && noCommandBar,
                     "a beta installs the companion once for Command Bar users with the island after setup, even over setup's off, and leaves it out once uninstalled")
        suite.expect(AppAppearance.sanitized(nil) == .system
                && AppAppearance.sanitized("nonsense") == .system,
               "an unknown stored appearance falls back to the system one")
        suite.expect(AppAppearance.sanitized("dark") == .dark && AppAppearance.sanitized("light") == .light,
               "stored appearance values survive a relaunch")
        suite.expect(AppAppearance.allCases.map(\.rawValue) == ["system", "light", "dark"],
               "appearance raw values are persisted keys and their order is the picker order")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeAutoStart] as? Bool == false,
               "Keep Awake launch restore is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeRightClickToggle] as? Bool == false,
               "right-click Keep Awake toggle is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeAllowDisplaySleep] as? Bool == false,
               "Keep Awake keeps the display on by default")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.keepAwakeRightClickToggle),
               "right-click Keep Awake preference follows settings backups")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.keepAwakeAllowDisplaySleep),
               "display sleep preference follows settings backups")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeExternalDisplay] as? Bool == false,
               "external-display Keep Awake is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeConnectedToPower] as? Bool == false,
               "power-connected Keep Awake is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeRunningApps] as? Bool == false,
               "running-apps Keep Awake is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeRunningAppBundleIDs] as? [String] == [],
               "running-apps Keep Awake starts with an empty app list")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeAutomationRequireAll] as? Bool == false,
               "matching every selected automation condition is opt-in")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.keepAwakeAutomationRequireAll),
               "the automation match mode follows settings backups")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.keepAwakeRunningApps),
               "running-apps Keep Awake preference follows settings backups")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.keepAwakeRunningAppBundleIDs),
               "running-apps Keep Awake app list follows settings backups")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakePauseWhenLocked] as? Bool == false,
               "pausing Keep Awake on screen lock is opt-in")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.keepAwakePauseWhenLocked),
               "the Keep Awake screen-lock preference follows settings backups")
        suite.expect(registeredDefaults[DefaultsKey.hotkeyEnabled] as? Bool == true,
               "global hotkey is on for clean installs")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeShortcut] as? String == "control+option+command:40",
               "keep awake shortcut defaults to Ctrl+Opt+Cmd+K")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeIconTint] as? String == KeepAwakeIconTint.orange.rawValue,
               "keep-awake active icon tint defaults to orange")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeActiveIcon] as? String == KeepAwakeActiveIcon.vorssaint.rawValue,
               "keep-awake active icon defaults to the Vorssaint glyph")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeMouseJiggleEnabled] as? Bool == false,
               "Keep Awake mouse movement is opt-in")
        suite.expect(registeredDefaults[DefaultsKey.keepAwakeMouseJiggleInterval] as? Int == 5,
               "Keep Awake mouse movement defaults to five minutes")
        suite.expect(Defaults.sanitizedKeepAwakeMouseJiggleInterval(10) == 10,
               "valid Keep Awake mouse movement interval is preserved")
        suite.expect(Defaults.sanitizedKeepAwakeMouseJiggleInterval(3) == 5,
               "invalid Keep Awake mouse movement interval falls back to five minutes")
        suite.expect(Defaults.sanitizedKeepAwakeIconTint("pink") == .pink,
               "valid keep-awake active icon tint is preserved")
        suite.expect(Defaults.sanitizedKeepAwakeIconTint("bad") == .orange,
               "invalid keep-awake active icon tint falls back to orange")
        suite.expect(Defaults.sanitizedKeepAwakeActiveIcon("coffee") == .coffee,
               "valid keep-awake active icon is preserved")
        suite.expect(Defaults.sanitizedKeepAwakeActiveIcon("bad") == .vorssaint,
               "invalid keep-awake active icon falls back to the Vorssaint glyph")
        suite.expect(KeepAwakeActiveIcon.eye.systemSymbolName == "eye.fill",
               "keep-awake eye option maps to its menu bar symbol")
        suite.expect(registeredDefaults[DefaultsKey.menuBarIconSymbol] as? String == "",
               "the menu bar shows the Vorssaint glyph until a symbol is chosen")
        suite.expect(Defaults.sanitizedMenuBarIconSymbol("  bolt.fill\n") == "bolt.fill"
                     && Defaults.sanitizedMenuBarIconSymbol(" ") == ""
                     && Defaults.sanitizedMenuBarIconSymbol(nil) == "",
               "a typed menu bar symbol name loses its surrounding spaces, and blank keeps the glyph")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.menuBarIconSymbol),
               "the chosen menu bar symbol follows settings backups")
        let symbolExists: (String) -> Bool = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
        suite.expect(Defaults.menuBarIconSymbolToSave(typed: " bolt.fill ", opening: "", exists: symbolExists) == "bolt.fill"
                     && Defaults.menuBarIconSymbolToSave(typed: "bolt.fil", opening: "star.fill", exists: symbolExists) == "star.fill"
                     && Defaults.menuBarIconSymbolToSave(typed: "  ", opening: "star.fill", exists: symbolExists) == "",
               "a typed menu bar symbol applies when this Mac has it, blank brings back the glyph, anything else keeps the opening icon")
        let gallery = Defaults.menuBarIconGallery
        suite.expect(gallery.count >= 30 && Set(gallery).count == gallery.count
                     && gallery.allSatisfy { !$0.isEmpty && Defaults.sanitizedMenuBarIconSymbol($0) == $0 },
               "the menu bar icon gallery offers many distinct symbol names")
        suite.expect(gallery.allSatisfy(symbolExists),
               "every symbol in the menu bar icon gallery exists on this Mac")
        suite.expect(KeepAwakeActiveIcon.allCases.compactMap(\.systemSymbolName).allSatisfy { !gallery.contains($0) },
               "the menu bar icon gallery leaves out Keep Awake's symbols, so an active session still stands out")
        suite.expect(!KeepAwakeAutomationSupport.hasExternalDisplay(builtInFlags: []),
               "no online display does not count as an external display")
        suite.expect(!KeepAwakeAutomationSupport.hasExternalDisplay(builtInFlags: [true]),
               "the built-in screen does not count as an external display")
        suite.expect(KeepAwakeAutomationSupport.hasExternalDisplay(builtInFlags: [true, false]),
               "an online non-built-in screen counts as an external display")
        suite.expect(!KeepAwakeAutomationSupport.selectedAppsAreRunning(
            selectedBundleIDs: [],
            runningBundleIDs: ["com.example.app"]
        ), "an empty selected-app list never matches a running app")
        suite.expect(!KeepAwakeAutomationSupport.selectedAppsAreRunning(
            selectedBundleIDs: ["com.example.app"],
            runningBundleIDs: ["com.other.app"]
        ), "a selected app that is not running does not match")
        suite.expect(KeepAwakeAutomationSupport.selectedAppsAreRunning(
            selectedBundleIDs: ["com.example.app", "com.other.app"],
            runningBundleIDs: ["com.helper", "com.example.app"]
        ), "any selected app that is running matches, focused or not")
        let combinedKeepAwakeConditions = KeepAwakeAutomationSupport.matchingConditions(
            externalDisplayEnabled: true,
            externalDisplayConnected: true,
            powerEnabled: true,
            connectedToPower: true,
            runningAppsEnabled: true,
            selectedAppsRunning: true
        )
        suite.expect(combinedKeepAwakeConditions == [.externalDisplay, .power, .runningApps],
               "enabled Keep Awake conditions combine with OR behavior")
        suite.expect(KeepAwakeAutomationSupport.matchingConditions(
            externalDisplayEnabled: false,
            externalDisplayConnected: false,
            powerEnabled: false,
            connectedToPower: false,
            runningAppsEnabled: true,
            selectedAppsRunning: true
        ) == [.runningApps], "a running selected app matches the running-apps condition")
        suite.expect(KeepAwakeAutomationSupport.matchingConditions(
            externalDisplayEnabled: false,
            externalDisplayConnected: false,
            powerEnabled: false,
            connectedToPower: false,
            runningAppsEnabled: true,
            selectedAppsRunning: false
        ).isEmpty, "running-apps stays off when none of the selected apps are open")
        suite.expect(KeepAwakeAutomationSupport.action(
            featureAvailable: true,
            matchingConditions: [.externalDisplay],
            sessionActive: false,
            automaticSessionActive: false
        ) == .activate, "an external display starts the automatic session")
        suite.expect(KeepAwakeAutomationSupport.action(
            featureAvailable: true,
            matchingConditions: [],
            sessionActive: true,
            automaticSessionActive: true
        ) == .deactivate, "clearing every matching condition ends the automatic session")
        suite.expect(KeepAwakeAutomationSupport.action(
            featureAvailable: true,
            matchingConditions: [],
            sessionActive: true,
            automaticSessionActive: false
        ) == .none, "clearing automatic conditions does not end a manual session")
        let bothDockConditions = KeepAwakeAutomationSupport.enabledConditions(
            externalDisplayEnabled: true, powerEnabled: true, runningAppsEnabled: false)
        suite.expect(bothDockConditions == [.externalDisplay, .power],
               "enabled conditions are collected whether or not they hold")
        suite.expect(KeepAwakeAutomationSupport.conditionsSatisfied(
            matching: [.externalDisplay], enabled: bothDockConditions, requireAll: false
        ), "Any keeps today's behavior: one matching condition is enough")
        suite.expect(!KeepAwakeAutomationSupport.conditionsSatisfied(
            matching: [.externalDisplay], enabled: bothDockConditions, requireAll: true
        ), "All refuses a session while one enabled condition is unmet")
        suite.expect(KeepAwakeAutomationSupport.conditionsSatisfied(
            matching: bothDockConditions, enabled: bothDockConditions, requireAll: true
        ), "All starts a session once every enabled condition is met")
        suite.expect(!KeepAwakeAutomationSupport.conditionsSatisfied(
            matching: [], enabled: [], requireAll: true
        ), "All never treats an empty selection as satisfied")
        let powerPlusUnnamedApps = KeepAwakeAutomationSupport.enabledConditions(
            externalDisplayEnabled: false, powerEnabled: true,
            runningAppsEnabled: true, hasSelectedApps: false)
        suite.expect(powerPlusUnnamedApps == [.power],
               "an app condition with no app named is not a condition All has to satisfy")
        suite.expect(KeepAwakeAutomationSupport.conditionsSatisfied(
            matching: [.power], enabled: powerPlusUnnamedApps, requireAll: true
        ), "All stays usable while the app list is still empty")
        suite.expect(KeepAwakeAutomationSupport.action(
            featureAvailable: true,
            matchingConditions: [.externalDisplay],
            enabledConditions: bothDockConditions,
            requireAll: true,
            sessionActive: false,
            automaticSessionActive: false
        ) == .none, "a monitor on battery does not start an All session")
        suite.expect(KeepAwakeAutomationSupport.action(
            featureAvailable: true,
            matchingConditions: [.runningApps],
            enabledConditions: KeepAwakeAutomationSupport.enabledConditions(
                externalDisplayEnabled: false, powerEnabled: true, runningAppsEnabled: true),
            requireAll: true,
            sessionActive: true,
            automaticSessionActive: true
        ) == .deactivate, "unplugging power ends an All session the running app alone would hold open")
        suite.expect(KeepAwakeAutomationSupport.action(
            featureAvailable: true,
            matchingConditions: [.runningApps],
            enabledConditions: KeepAwakeAutomationSupport.enabledConditions(
                externalDisplayEnabled: false, powerEnabled: true, runningAppsEnabled: true),
            requireAll: false,
            sessionActive: true,
            automaticSessionActive: true
        ) == .none, "the same unplug leaves an Any session running, which is why All exists")
        let automationEditor = (try? String(
            contentsOfFile: "Sources/Vorssaint/UI/KeepAwakeAutomationView.swift",
            encoding: .utf8)) ?? ""
        suite.expect(automationEditor.contains(".pickerStyle(.segmented)")
                && automationEditor.contains(".controlSize(compact ? .small : .regular)"),
               "the match mode picker follows the compact layout of the panel card")
        let matchModeWidth = 308.0 - 20 - 19 - 22
        for language in AppLanguage.allCases {
            let strings = FeatureStrings.keepAwakeAutomation(language)
            let control = NSSegmentedControl(labels: [strings.matchAny, strings.matchAll],
                                             trackingMode: .selectOne, target: nil, action: nil)
            control.controlSize = .small
            control.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            control.sizeToFit()
            let width = Double(control.fittingSize.width)
            suite.expect(width > 0 && width <= matchModeWidth,
                   "\(language.rawValue): the match mode labels fit the panel card "
                   + "(\(Int(width))pt of \(Int(matchModeWidth))pt)")
        }
        suite.expect(!KeepAwakeAutomationSupport.conditionsSatisfied(
            matching: [.externalDisplay], enabled: bothDockConditions, requireAll: true
        ), "a timer running out on battery hands nothing over to an All automation")
        suite.expect(KeepAwakeAutomationSupport.conditionsSatisfied(
            matching: [.externalDisplay], enabled: bothDockConditions, requireAll: false
        ), "the same timer still hands over under Any")
        suite.expect(KeepAwakeAutomationSupport.isScreenLocked(
            sessionDictionary: ["CGSSessionScreenIsLocked": true]
        ), "the Keep Awake lock guard reads a locked session")
        suite.expect(!KeepAwakeAutomationSupport.isScreenLocked(
            sessionDictionary: ["CGSSessionScreenIsLocked": false]
        ), "the Keep Awake lock guard reads an unlocked session")
        suite.expect(KeepAwakeAutomationSupport.isScreenLocked(
            sessionDictionary: ["CGSSessionScreenIsLocked": NSNumber(value: true)]
        ), "the Keep Awake lock guard accepts the session dictionary's numeric bridge")
        suite.expect(!KeepAwakeAutomationSupport.isScreenLocked(sessionDictionary: nil),
               "an unreadable lock state does not strand Keep Awake in a pause")
        let cal = Calendar.current
        let now10 = cal.date(from: DateComponents(
            year: 2026, month: 1, day: 15, hour: 10, minute: 0))!
        let pick14 = cal.date(from: DateComponents(
            year: 2026, month: 1, day: 15, hour: 14, minute: 30))!
        let resolved1 = KeepAwakeAutomationSupport.resolvedUntilDate(picked: pick14, now: now10)
        suite.expect(cal.component(.hour, from: resolved1) == 14
                && cal.component(.day, from: resolved1) == 15,
               "resolvedUntilDate keeps a time still ahead today on today")
        let now22 = cal.date(from: DateComponents(
            year: 2026, month: 1, day: 15, hour: 22, minute: 0))!
        let pick7 = cal.date(from: DateComponents(
            year: 2026, month: 1, day: 15, hour: 7, minute: 0))!
        let resolved2 = KeepAwakeAutomationSupport.resolvedUntilDate(picked: pick7, now: now22)
        suite.expect(cal.component(.hour, from: resolved2) == 7
                && cal.component(.day, from: resolved2) == 16,
               "resolvedUntilDate rolls a time already past today to tomorrow")
        let sleepDisabledReport = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
        """
        let sleepEnabledReport = """
        System-wide power settings:
         SleepDisabled\t\t0
        Currently in use:
         standby              1
        """
        suite.expect(SudoersSupport.sleepDisabled(inPmsetOutput: sleepDisabledReport),
               "a pmset report with SleepDisabled 1 reads as lid sleep disabled")
        suite.expect(!SudoersSupport.sleepDisabled(inPmsetOutput: sleepEnabledReport),
               "a pmset report with SleepDisabled 0 reads as lid sleep enabled")
        suite.expect(!SudoersSupport.sleepDisabled(inPmsetOutput: ""),
               "an empty pmset report reads as lid sleep enabled")
        // The rule is granted by uid so every short name works, including the
        // email-style ones SSO enrollment produces (#915). The uid renders as
        // bare digits and the rest is a fixed literal, so the whole line must
        // stay inside a character set that neither sudoers nor a single-quoted
        // shell string can read as anything but itself.
        suite.expect(SudoersSupport.clamshellRule(uid: 501)
               == "#501 ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0",
               "the closed-lid sudoers rule grants pmset disablesleep to the uid")
        suite.expect(SudoersSupport.clamshellRule(uid: uid_t.max)
               .range(of: #"^#[0-9]+ [A-Za-z0-9()=:,./ ]+$"#, options: .regularExpression) != nil,
               "the closed-lid sudoers rule never contains shell or sudoers metacharacters")

        // Enterprise fallback: Keychain credential lookup returns nil for unknown service
        suite.expect(SudoersSupport.keychainPassword(services: ["__nonexistent_test_service__"]) == nil,
               "keychain lookup returns nil when no entry exists for service")

        // Enterprise fallback: PTY runner safely handles empty command
        let emptyResult = SudoersSupport.runViaPTY(command: [], password: "")
        suite.expect(emptyResult.status != 0,
               "PTY runner reports error on empty command")

        // Enterprise fallback: PTY runner handles successful command execution
        let echoResult = SudoersSupport.runViaPTY(command: ["/bin/echo", "pty_test_ok"], password: "")
        suite.expect(echoResult.status == 0 && echoResult.output.contains("pty_test_ok"),
               "PTY runner executes command successfully and captures output")

        // Enterprise fallback: PTY runner resolves bare command names via PATH (execvp)
        let unpathedResult = SudoersSupport.runViaPTY(command: ["echo", "pty_unpathed_ok"], password: "")
        suite.expect(unpathedResult.status == 0 && unpathedResult.output.contains("pty_unpathed_ok"),
               "PTY runner resolves bare commands via PATH")

        // Enterprise fallback: PTY runner preserves non-zero exit code
        let falseResult = SudoersSupport.runViaPTY(command: ["/usr/bin/false"], password: "")
        suite.expect(falseResult.status == 1,
               "PTY runner reports non-zero exit code for failing command")

        // Enterprise fallback: PTY runner detects password prompt and feeds credential
        let promptCmd = ["/bin/sh", "-c", "read -p 'Password: ' pw; [ \"$pw\" = 'correct_pass_123' ]"]
        let promptSuccess = SudoersSupport.runViaPTY(command: promptCmd, password: "correct_pass_123")
        suite.expect(promptSuccess.status == 0,
               "PTY runner detects password prompt and feeds credential")

        // Enterprise fallback: PTY runner reports non-zero exit when password verification fails
        let promptFailure = SudoersSupport.runViaPTY(command: promptCmd, password: "wrong_pass_456")
        suite.expect(promptFailure.status != 0,
               "PTY runner reports non-zero exit when password verification fails")

        // Enterprise fallback: PTY runner aborts promptly upon authentication rejection banner
        let rejectCmd = ["/bin/sh", "-c", "echo 'Password: '; read pw; echo 'Sorry, try again.'; sleep 4"]
        let rejectStart = Date()
        _ = SudoersSupport.runViaPTY(command: rejectCmd, password: "pw", timeout: 6.0)
        let rejectDuration = Date().timeIntervalSince(rejectStart)
        suite.expect(rejectDuration < 3.0,
               "PTY runner aborts promptly upon authentication rejection banner")

        // Enterprise fallback: saveKeychainPassword stores credential in login Keychain via SecItemAdd
        let testService = "vorssaint-test-kc-\(UUID().uuidString)"
        let testAccount = "test-user-\(UUID().uuidString)"
        let initialLookup = SudoersSupport.keychainPassword(services: [testService], account: testAccount)
        suite.expect(initialLookup == nil,
               "keychain password lookup returns nil for unused test service")

        let saved = SudoersSupport.saveKeychainPassword("test-secret-1234", service: testService, account: testAccount)
        suite.expect(saved,
               "saveKeychainPassword succeeds using SecItemAdd")

        let queried = SudoersSupport.keychainPassword(services: [testService], account: testAccount)
        suite.expect(queried == "test-secret-1234",
               "keychainPassword successfully queries saved credential")

        // Enterprise fallback: duplicate update fallback via SecItemUpdate
        let updated = SudoersSupport.saveKeychainPassword("test-secret-5678", service: testService, account: testAccount)
        suite.expect(updated,
               "saveKeychainPassword succeeds on duplicate item using SecItemUpdate")

        let queriedUpdated = SudoersSupport.keychainPassword(services: [testService], account: testAccount)
        suite.expect(queriedUpdated == "test-secret-5678",
               "keychainPassword retrieves updated credential after duplicate save")

        // Enterprise fallback: deletion via deleteKeychainPassword
        let deleted = SudoersSupport.deleteKeychainPassword(service: testService, account: testAccount)
        suite.expect(deleted,
               "deleteKeychainPassword removes item from keychain")

        let queriedAfterDelete = SudoersSupport.keychainPassword(services: [testService], account: testAccount)
        suite.expect(queriedAfterDelete == nil,
               "keychainPassword returns nil after credential deletion")

        // Enterprise fallback: promptForElevationPassword delivers entered password via completion
        var promptResult: String?
        SudoersSupport.mockElevationPromptHandler = { completion in
            completion("mocked-pass")
        }
        SudoersSupport.promptForElevationPassword { pw in
            promptResult = pw
        }
        suite.expect(promptResult == "mocked-pass",
               "promptForElevationPassword delivers entered password via completion")

        // Enterprise fallback: promptForElevationPassword delivers nil when user cancels
        SudoersSupport.mockElevationPromptHandler = { completion in
            completion(nil)
        }
        var cancelResult: String? = "preset"
        SudoersSupport.promptForElevationPassword { pw in
            cancelResult = pw
        }
        suite.expect(cancelResult == nil,
               "promptForElevationPassword delivers nil when user cancels")

        // Enterprise fallback: saveKeychainPassword rejects empty string
        let emptySave = SudoersSupport.saveKeychainPassword("", service: testService, account: testAccount)
        suite.expect(!emptySave,
               "saveKeychainPassword rejects empty password")

        // Enterprise lifecycle: isolated setup using dedicated testService and ruleFileDetector mock
        let originalPrimary = SudoersSupport.primaryKeychainService
        let originalServices = SudoersSupport.keychainServices
        let originalDetector = Sudoers.ruleFileDetector
        let originalLegacy = SudoersSupport.legacyKeychainServices
        SudoersSupport.primaryKeychainService = testService
        SudoersSupport.keychainServices = [testService]
        Sudoers.ruleFileDetector = { false }
        // Never touch the real hand-made legacy item: record removals instead.
        let legacyService = "vorssaint-test-legacy-\(UUID().uuidString)"
        var legacyRemovals: [String] = []
        SudoersSupport.legacyKeychainServices = [legacyService]
        SudoersSupport.legacyItemRemover = { service, _ in legacyRemovals.append(service) }

        // Enterprise lifecycle: Sudoers.install returns false when prompt is canceled
        var installCancelResult: Bool?
        let sema1 = DispatchSemaphore(value: 0)
        SudoersSupport.deleteKeychainPassword(service: testService)
        SudoersSupport.mockElevationPromptHandler = { completion in
            completion(nil)
        }
        Sudoers.permitCredentialRequest()
        Sudoers.install { ok in
            installCancelResult = ok
            sema1.signal()
        }
        _ = sema1.wait(timeout: .now() + 3.0)
        suite.expect(installCancelResult == false,
               "Sudoers.install returns false when prompt is canceled")

        // Enterprise lifecycle: Sudoers.install returns false and purges bad credential when PTY verification fails
        var installFailResult: Bool?
        let sema2 = DispatchSemaphore(value: 0)
        SudoersSupport.deleteKeychainPassword(service: testService)
        SudoersSupport.mockElevationPromptHandler = { completion in
            completion("wrong-enterprise-pass")
        }
        SudoersSupport.verificationRunner = { _, _ in
            return (1, "sudo: 1 incorrect password attempt")
        }
        Sudoers.permitCredentialRequest()
        Sudoers.install { ok in
            installFailResult = ok
            sema2.signal()
        }
        _ = sema2.wait(timeout: .now() + 3.0)
        suite.expect(installFailResult == false,
               "Sudoers.install returns false when password verification fails")
        suite.expect(SudoersSupport.keychainPassword(services: [testService]) == nil,
               "Sudoers.install removes bad password from keychain on verification failure")

        // Enterprise lifecycle: Sudoers.install saves and marks ok = true when PTY verification succeeds
        var installSuccessResult: Bool?
        let sema3 = DispatchSemaphore(value: 0)
        SudoersSupport.deleteKeychainPassword(service: testService)
        SudoersSupport.mockElevationPromptHandler = { completion in
            completion("valid-enterprise-pass-1234")
        }
        SudoersSupport.verificationRunner = { _, _ in
            return (0, "SleepDisabled 0")
        }
        Sudoers.permitCredentialRequest()
        Sudoers.install { ok in
            installSuccessResult = ok
            sema3.signal()
        }
        _ = sema3.wait(timeout: .now() + 3.0)
        suite.expect(installSuccessResult == true,
               "Sudoers.install returns true when password verifies successfully")
        suite.expect(SudoersSupport.keychainPassword(services: [testService]) == "valid-enterprise-pass-1234",
               "Sudoers.install retains verified password in keychain")

        suite.expect(Sudoers.holdsCredential && legacyRemovals == [legacyService],
               "a verified password is held in memory and the hand-made legacy item is removed")

        // Credential policy: probes use the held copy and never read the keychain.
        var typedPasswords: [String] = []
        SudoersSupport.verificationRunner = { _, password in
            typedPasswords.append(password)
            return (0, "")
        }
        var reads = SudoersSupport.keychainReadCount
        suite.expect(Sudoers.isConfigured() && typedPasswords == ["valid-enterprise-pass-1234"]
               && SudoersSupport.keychainReadCount == reads,
               "a status probe uses the held password without reading the keychain")
        Sudoers.releaseCredentialAfterQueuedWrites()
        suite.expect(!Sudoers.isConfigured() && !Sudoers.holdsCredential
               && SudoersSupport.keychainReadCount == reads,
               "after release a probe reports not configured and still reads nothing")

        // Credential policy: without the toggle's permit, setup asks for nothing.
        var dialogs = 0
        SudoersSupport.mockElevationPromptHandler = { completion in dialogs += 1; completion("unused-pass") }
        var unpermitted: Bool?
        let sema5 = DispatchSemaphore(value: 0)
        Sudoers.install { ok in unpermitted = ok; sema5.signal() }
        _ = sema5.wait(timeout: .now() + 3.0)
        suite.expect(unpermitted == false && dialogs == 0 && SudoersSupport.keychainReadCount == reads,
               "setup that the toggle did not start shows no dialog and reads no keychain item")

        let originalLifetime = Sudoers.credentialPermitLifetime
        Sudoers.credentialPermitLifetime = -1
        Sudoers.permitCredentialRequest()
        var expired: Bool?
        let sema6 = DispatchSemaphore(value: 0)
        Sudoers.install { ok in expired = ok; sema6.signal() }
        _ = sema6.wait(timeout: .now() + 3.0)
        Sudoers.credentialPermitLifetime = originalLifetime
        suite.expect(expired == false && dialogs == 0,
               "an expired permit cannot open the password dialog")

        // Credential policy: the stored copy is used first, without the dialog.
        legacyRemovals = []
        Sudoers.permitCredentialRequest()
        var fromStore: Bool?
        let sema7 = DispatchSemaphore(value: 0)
        Sudoers.install { ok in fromStore = ok; sema7.signal() }
        _ = sema7.wait(timeout: .now() + 3.0)
        suite.expect(fromStore == true && dialogs == 0 && Sudoers.holdsCredential
               && SudoersSupport.keychainReadCount == reads + 1 && legacyRemovals == [legacyService],
               "switching on with a stored password makes one keychain read and no dialog")
        reads = SudoersSupport.keychainReadCount

        // Credential policy: a rejected password is dropped and never retried.
        SudoersSupport.verificationRunner = { _, _ in (SudoersSupport.passwordRejectedStatus, "Sorry, try again.") }
        suite.expect(!Sudoers.isConfigured() && !Sudoers.holdsCredential,
               "a password sudo rejects is dropped from memory")
        SudoersSupport.verificationRunner = { _, _ in (0, "") }
        suite.expect(!Sudoers.isConfigured() && SudoersSupport.keychainReadCount == reads,
               "a rejected password is not tried again by later probes")
        SudoersSupport.mockElevationPromptHandler = { completion in dialogs += 1; completion("renewed-pass-1234") }
        Sudoers.permitCredentialRequest()
        var renewed: Bool?
        let sema8 = DispatchSemaphore(value: 0)
        Sudoers.install { ok in renewed = ok; sema8.signal() }
        _ = sema8.wait(timeout: .now() + 3.0)
        suite.expect(renewed == true && dialogs == 1 && SudoersSupport.keychainReadCount == reads
               && SudoersSupport.keychainPassword(services: [testService]) == "renewed-pass-1234",
               "after a rejection the next switch-on asks for the password instead of reusing the stored one")

        // PTY runner: only a real prompt gets the password, and a second prompt is a rejection.
        suite.expect(SudoersSupport.endsWithPasswordPrompt("Password:")
               && SudoersSupport.endsWithPasswordPrompt("[sudo] password for dev: ")
               && !SudoersSupport.endsWithPasswordPrompt("Your password expires in 3 days")
               && !SudoersSupport.endsWithPasswordPrompt("Password policy:\nmanaged by EPM\n"),
               "only a trailing line that names a password and ends with a colon counts as a prompt")
        let banner = SudoersSupport.runViaPTY(
            command: ["/bin/bash", "-c", "echo 'Your password expires in 3 days'; read -t 2 pw; [ -z \"$pw\" ]"],
            password: "never-typed", timeout: 5.0)
        suite.expect(banner.status == 0 && !banner.output.contains("never-typed"),
               "a banner that mentions passwords never gets the password typed at it")
        let repromptStart = Date()
        let reprompt = SudoersSupport.runViaPTY(
            command: ["/bin/bash", "-c", "read -s -p 'Password: ' a; echo; read -s -p 'Password: ' b; sleep 4"],
            password: "wrong", timeout: 6.0)
        suite.expect(reprompt.status == SudoersSupport.passwordRejectedStatus
               && Date().timeIntervalSince(repromptStart) < 3.0,
               "a second password prompt is reported as a rejection right away")

        // Enterprise lifecycle: Sudoers.remove purges credential from Keychain
        var removeResult: Bool?
        let sema4 = DispatchSemaphore(value: 0)
        Sudoers.remove { ok in
            removeResult = ok
            sema4.signal()
        }
        _ = sema4.wait(timeout: .now() + 3.0)
        suite.expect(removeResult == true,
               "Sudoers.remove succeeds")
        suite.expect(SudoersSupport.keychainPassword(services: [testService]) == nil,
               "Sudoers.remove purges elevation password from keychain")
        suite.expect(!Sudoers.holdsCredential && legacyRemovals.last == legacyService,
               "Sudoers.remove also drops the held password and the legacy item")

        SudoersSupport.primaryKeychainService = originalPrimary
        SudoersSupport.keychainServices = originalServices
        SudoersSupport.legacyKeychainServices = originalLegacy
        SudoersSupport.legacyItemRemover = nil
        Sudoers.ruleFileDetector = originalDetector
        SudoersSupport.mockElevationPromptHandler = nil
        SudoersSupport.verificationRunner = nil
        SudoersSupport.deleteKeychainPassword(service: testService)
    }
}
