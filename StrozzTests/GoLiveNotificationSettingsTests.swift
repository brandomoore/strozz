import XCTest

@testable import Strozz

@MainActor
final class GoLiveNotificationSettingsTests: XCTestCase {
  private func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
    let name = "GoLiveNotificationSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try test(defaults)
  }

  func testFreshInstallIsOffWithNoImplicitChannelConsent() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      XCTAssertEqual(settings.mode, .off)
      XCTAssertFalse(settings.hasPrompted)
      XCTAssertFalse(settings.hasEnabledChannels)
      XCTAssertFalse(settings.isAlerting(login: "alpha"))
    }
  }

  func testLegacyPreferencesResetOffAndAskOnceRegardlessOfPreviousMasterSwitch() {
    withDefaults { defaults in
      for enabled in [true, false] {
        defaults.set(enabled, forKey: PersistenceKey.goLiveNotificationsEnabled)
        defaults.set(["alpha"], forKey: PersistenceKey.goLiveMutedChannels)
        let settings = GoLiveNotificationSettings(defaults: defaults)
        XCTAssertEqual(settings.mode, .off)
        XCTAssertFalse(settings.hasPrompted)
        XCTAssertFalse(settings.isAlerting(login: "alpha"))
        XCTAssertFalse(settings.isAlerting(login: "beta"))
      }
    }
  }

  func testPresentingPromptDoesNotEnableAlertsAndPersistsAcrossLaunches() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      settings.markPromptPresented()
      settings.markPromptPresented()
      let restored = GoLiveNotificationSettings(defaults: defaults)
      XCTAssertTrue(restored.hasPrompted)
      XCTAssertFalse(restored.hasEnabledChannels)
      XCTAssertEqual(restored.mode, .off)
    }
  }

  func testSettingsChoiceBeforePromptAlsoCompletesTheOneTimeAsk() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      settings.disableAll()
      XCTAssertTrue(GoLiveNotificationSettings(defaults: defaults).hasPrompted)
    }
  }

  func testAllIncludesFutureFollowsAndSurvivesRelaunch() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      settings.enableAll()
      let restored = GoLiveNotificationSettings(defaults: defaults)
      XCTAssertEqual(restored.mode, .all)
      XCTAssertTrue(restored.hasEnabledChannels)
      XCTAssertTrue(restored.hasPrompted)
      XCTAssertTrue(restored.isAlerting(login: "futurefollow"))
    }
  }

  func testDisablingOneFromAllSnapshotsEveryCurrentFollowThenStopsNewFollows() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      settings.enableAll()
      settings.setAlerting(false, login: "alpha", followedLogins: ["alpha", "beta", "offline"])
      let restored = GoLiveNotificationSettings(defaults: defaults)
      XCTAssertEqual(restored.mode, .selected)
      XCTAssertFalse(restored.isAlerting(login: "alpha"))
      XCTAssertTrue(restored.isAlerting(login: "beta"))
      XCTAssertTrue(restored.isAlerting(login: "offline"))
      XCTAssertFalse(restored.isAlerting(login: "futurefollow"))
      restored.setAlerting(true, login: "alpha", followedLogins: ["alpha", "beta", "offline"])
      XCTAssertEqual(restored.mode, .selected)
      XCTAssertFalse(restored.isAlerting(login: "futurefollow"))
      restored.enableAll()
      XCTAssertTrue(restored.isAlerting(login: "futurefollow"))
    }
  }

  func testOpeningPickerDoesNotChangeAllPolicyUntilAnActualEdit() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      settings.enableAll()
      settings.beginChoosingChannels()
      settings.setAlerting(true, login: "alpha", followedLogins: ["alpha"])
      XCTAssertEqual(settings.mode, .all)
      XCTAssertTrue(settings.isAlerting(login: "futurefollow"))
    }
  }

  func testChoosingChannelsFromOffStartsEmptyAndEnablesOnlyExplicitSelection() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      settings.beginChoosingChannels()
      XCTAssertEqual(settings.mode, .selected)
      XCTAssertFalse(settings.hasEnabledChannels)
      XCTAssertTrue(settings.hasPrompted)
      settings.setAlerting(true, login: " Alpha ", followedLogins: ["alpha", "beta"])
      XCTAssertTrue(settings.hasEnabledChannels)
      XCTAssertTrue(settings.isAlerting(login: "ALPHA"))
      XCTAssertFalse(settings.isAlerting(login: "beta"))
      XCTAssertFalse(settings.isAlerting(login: "futurefollow"))
    }
  }

  func testSearchDisableUsesFullDirectoryNotOnlySearchMatches() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      settings.enableAll()
      settings.setAlerting(false, logins: ["alpha", "bravo"], followedLogins: ["alpha", "bravo", "charlie"])
      XCTAssertFalse(settings.isAlerting(login: "alpha"))
      XCTAssertFalse(settings.isAlerting(login: "bravo"))
      XCTAssertTrue(settings.isAlerting(login: "charlie"))
      XCTAssertFalse(settings.isAlerting(login: "futurefollow"))
    }
  }

  func testSearchEnableOnlyOptsIntoMatchesEvenWhenEveryCurrentFollowMatches() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      settings.setAlerting(true, logins: ["alpha", "bravo"], followedLogins: ["alpha", "bravo"])
      XCTAssertTrue(settings.isAlerting(login: "alpha"))
      XCTAssertTrue(settings.isAlerting(login: "bravo"))
      XCTAssertEqual(settings.mode, .selected)
      XCTAssertFalse(settings.isAlerting(login: "futurefollow"))
    }
  }

  func testDisableAllClearsSelectionAndDoesNotReenableOnOpeningPicker() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      settings.setAlerting(true, login: "alpha", followedLogins: ["alpha"])
      settings.disableAll()
      let restored = GoLiveNotificationSettings(defaults: defaults)
      XCTAssertEqual(restored.mode, .off)
      XCTAssertTrue(restored.hasPrompted)
      restored.beginChoosingChannels()
      XCTAssertFalse(restored.hasEnabledChannels)
      XCTAssertFalse(restored.isAlerting(login: "alpha"))
    }
  }

  func testMalformedStoredPreferencesFailClosed() {
    withDefaults { defaults in
      defaults.set(Data(#"{"mode":"unknown","hasPrompted":true}"#.utf8), forKey: PersistenceKey.goLivePreferences)
      let settings = GoLiveNotificationSettings(defaults: defaults)
      XCTAssertEqual(settings.mode, .off)
      XCTAssertFalse(settings.isAlerting(login: "alpha"))
    }
  }

  func testMissingSettingsAndDefaultOffCannotPresentAnyToast() {
    withDefaults { defaults in
      let watcher = GoLiveWatcher()
      defer { watcher.stop() }
      watcher.enqueue(event("alpha"))
      XCTAssertNil(watcher.pending)
      let settings = GoLiveNotificationSettings(defaults: defaults)
      watcher.notificationSettings = settings
      watcher.enqueue(event("alpha"))
      XCTAssertNil(watcher.pending)
    }
  }

  func testTurningOffImmediatelyClearsCurrentAndQueuedToasts() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      let watcher = GoLiveWatcher()
      defer { watcher.stop() }
      watcher.notificationSettings = settings
      settings.enableAll()
      watcher.enqueue(event("alpha"))
      watcher.enqueue(event("beta"))
      XCTAssertEqual(watcher.pending?.login, "alpha")
      settings.disableAll()
      XCTAssertNil(watcher.pending)
      XCTAssertEqual(watcher.secondsRemaining, 0)
      settings.enableAll()
      watcher.dismissCurrent()
      XCTAssertNil(watcher.pending)
    }
  }

  func testDisablingPendingChannelAdvancesOnlyToAnAllowedQueuedChannel() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      let watcher = GoLiveWatcher()
      defer { watcher.stop() }
      watcher.notificationSettings = settings
      settings.enableAll()
      watcher.enqueue(event("alpha"))
      watcher.enqueue(event("beta"))
      watcher.enqueue(event("futurefollow"))
      settings.setAlerting(false, login: "alpha", followedLogins: ["alpha", "beta"])
      XCTAssertEqual(watcher.pending?.login, "beta")
      watcher.dismissCurrent()
      XCTAssertNil(watcher.pending)
    }
  }

  func testCustomSelectionAndCurrentlyWatchedChannelAreRespectedAtDelivery() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      let watcher = GoLiveWatcher()
      defer { watcher.stop() }
      watcher.notificationSettings = settings
      settings.setAlerting(true, login: "alpha", followedLogins: ["alpha", "beta"])
      watcher.enqueue(event("beta"))
      XCTAssertNil(watcher.pending)
      watcher.suppressedLogin = "ALPHA"
      watcher.enqueue(event("alpha"))
      XCTAssertNil(watcher.pending)
      watcher.suppressedLogin = nil
      watcher.enqueue(event("alpha"))
      XCTAssertEqual(watcher.watch(), "alpha")
      XCTAssertNil(watcher.pending)
    }
  }

  func testRemovingSettingsRevokesQueuedAndCurrentAlerts() {
    withDefaults { defaults in
      let settings = GoLiveNotificationSettings(defaults: defaults)
      let watcher = GoLiveWatcher()
      defer { watcher.stop() }
      watcher.notificationSettings = settings
      settings.enableAll()
      watcher.enqueue(event("alpha"))
      watcher.enqueue(event("beta"))
      watcher.notificationSettings = nil
      XCTAssertNil(watcher.pending)
      watcher.dismissCurrent()
      XCTAssertNil(watcher.pending)
    }
  }

  private func event(_ login: String) -> GoLiveEvent {
    GoLiveEvent(login: login, displayName: login, gameName: "Test", profileImageURL: nil)
  }
}
