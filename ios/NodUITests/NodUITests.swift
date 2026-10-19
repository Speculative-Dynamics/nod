// NodUITests.swift
// End-to-end tests for every user-facing feature of Nod. Each test
// launches the real app from a clean state (`-nodReset YES`) with the
// splash skipped, and, unless it's testing a real engine, the scripted
// reply engine (`-nodFakeEngine`), whose replies carry markers:
//
//   Heard: <message>. Remembered: <recall>. About you: <note>. (history N, limit M)
//
// so a test can confirm that history, memory recall and settings really
// reached the engine, not just that something appeared on screen.

import XCTest

final class NodUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let app, testRun?.hasSucceeded == false, app.state == .runningForeground {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "failure"
            shot.lifetime = .keepAlways
            add(shot)
            print("UI TREE AT FAILURE (\(name)):\n\(app.debugDescription)")
        }
    }

    // MARK: - Helpers

    @discardableResult
    func launch(engine: String? = "on", reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-nodSkipSplash", "YES"]
        if reset { args += ["-nodReset", "YES"] }
        if let engine { args += ["-nodFakeEngine", engine] }
        app.launchArguments = args + extra
        app.launch()
        self.app = app
        return app
    }

    /// The message field (a vertical TextField is exposed as a text view
    /// or a text field depending on the OS).
    var messageField: XCUIElement {
        let view = app.textViews["Message"]
        return view.exists ? view : app.textFields["Message"]
    }

    var sendButton: XCUIElement { app.buttons["Send message"] }
    var stopButton: XCUIElement { app.buttons["Stop response"] }

    func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    /// Visible text elements containing `text` (not their containers,
    /// whose combined labels would double-count).
    func count(containing text: String) -> Int {
        app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .count
    }

    func send(_ text: String) {
        let field = messageField
        XCTAssertTrue(field.waitForExistence(timeout: 10), "message field")
        field.tap()
        field.typeText(text)
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        sendButton.tap()
    }

    /// Waits for a finished scripted reply (its last marker) and returns
    /// the reply's accessibility label.
    @discardableResult
    func waitForReply(to text: String, timeout: TimeInterval = 20) -> String {
        let reply = element(containing: "Heard: \(text)")
        XCTAssertTrue(reply.waitForExistence(timeout: timeout), "reply to \(text)")
        let done = NSPredicate(format: "label CONTAINS 'limit '")
        expectation(for: done, evaluatedWith: reply)
        waitForExpectations(timeout: timeout)
        return reply.label
    }

    func sendAndWait(_ text: String) -> String {
        send(text)
        return waitForReply(to: text)
    }

    func openSettings() {
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func closeSheet() {
        app.buttons["Done"].firstMatch.tap()
    }

    /// SwiftUI list toggles flip only when the switch itself is tapped,
    /// not the label, so tap near the row's trailing edge.
    func tapSwitch(_ toggle: XCUIElement) {
        let inner = toggle.switches.firstMatch
        if inner.exists {
            scrollTo(inner)
            inner.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
    }

    func scrollTo(_ element: XCUIElement, in scrollable: XCUIElement? = nil, maxSwipes: Int = 8) {
        let container = scrollable ?? app.collectionViews.firstMatch
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            container.swipeUp()
            swipes += 1
        }
    }

    // MARK: - Empty state

    func testEmptyStateShowsGreetingAndStarters() {
        launch()
        XCTAssertTrue(app.buttons["I had a rough day"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Something's on my mind"].exists)
        XCTAssertTrue(app.buttons["I just need to vent"].exists)
        XCTAssertTrue(app.buttons["What Nod remembers"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    func testStarterFillsMessageFieldWithoutSending() {
        launch()
        app.buttons["Something's on my mind"].tap()
        XCTAssertEqual(messageField.value as? String, "Something's on my mind")
        XCTAssertFalse(element(containing: "You said:").exists, "a starter must not send")
        sendButton.tap()
        waitForReply(to: "Something's on my mind")
    }

    // MARK: - Conversation

    func testSendShowsMessageAndStreamedReply() {
        launch()
        let label = sendAndWait("hello there")
        XCTAssertTrue(element(containing: "You said: hello there").exists)
        XCTAssertTrue(label.contains("(history 0, limit 300)"), label)
        XCTAssertEqual(messageField.value as? String ?? "", messageField.placeholderValue ?? "", "field clears after send")
    }

    func testEarlierTurnsReachTheEngine() {
        launch()
        _ = sendAndWait("first message")
        let second = sendAndWait("second message")
        XCTAssertTrue(second.contains("(history 2,"), second)
    }

    func testStopKeepsPartialReplyAndMarksItStopped() {
        launch(engine: "slow")
        send("please talk for a while about something")
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Nod said: Heard:").waitForExistence(timeout: 10))
        stopButton.tap()
        XCTAssertTrue(element(containing: "stopped").waitForExistence(timeout: 5))
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "send returns after stop")
        XCTAssertFalse(element(containing: "limit 300)").exists, "reply was cut short")
    }

    func testFailedReplyShowsErrorRowAndTryAgainReplacesIt() {
        launch(engine: "failFirst")
        send("hello")
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Nod couldn't reply this time.").exists)
        app.buttons["Try again"].tap()
        waitForReply(to: "hello")
        XCTAssertFalse(element(containing: "Nod couldn't reply").exists, "error row replaced by the reply")
    }

    func testRepeatedFailureDoesNotStackErrors() {
        launch(engine: "fail")
        send("hello")
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
        app.buttons["Try again"].tap()
        sleep(2)
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
        XCTAssertEqual(count(containing: "Nod couldn't reply this time."), 1)
    }

    func testFailedTurnIsLeftOutOfHistory() {
        launch(engine: "failFirst")
        send("this one fails")
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
        // Send something new instead of retrying: the error row must not
        // reach the engine as a Nod turn.
        let label = sendAndWait("moving on")
        XCTAssertTrue(label.contains("(history 1,"), "only the user's earlier message: \(label)")
    }

    func testLongPressOffersCopyShareAndRegenerate() {
        launch()
        _ = sendAndWait("regenerate me")
        element(containing: "Nod said: Heard: regenerate me").press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Regenerate"].exists)
        app.buttons["Regenerate"].tap()
        sleep(3)
        waitForReply(to: "regenerate me")
        XCTAssertEqual(count(containing: "Nod said: Heard: regenerate me"), 1, "old reply replaced")
    }

    func testCopyPutsReplyOnPasteboard() {
        launch()
        _ = sendAndWait("copy this")
        element(containing: "Nod said: Heard: copy this").press(forDuration: 1.0)
        app.buttons["Copy"].tap()
        // Paste into the field to read the pasteboard back.
        messageField.tap()
        messageField.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        guard paste.waitForExistence(timeout: 5) else {
            XCTFail("no Paste menu")
            return
        }
        paste.tap()
        XCTAssertTrue((messageField.value as? String ?? "").contains("Heard: copy this"))
    }

    func testCrisisMessageShowsHelplineCard() {
        launch()
        _ = sendAndWait("sometimes I want to die")
        let card = element(containing: "please talk to someone now")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let helplines = app.buttons["Other helplines"].exists || app.buttons["Find a helpline near you"].exists
        XCTAssertTrue(helplines)
    }

    func testOrdinaryMessageShowsNoHelplineCard() {
        launch()
        _ = sendAndWait("the commute was long today")
        XCTAssertFalse(element(containing: "please talk to someone now").exists)
    }

    func testCommandKFocusesTheMessageField() {
        launch()
        XCTAssertTrue(messageField.waitForExistence(timeout: 10))
        XCTAssertFalse(messageField.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "starts unfocused")
        app.typeKey("k", modifierFlags: .command)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: messageField)
        waitForExpectations(timeout: 5)
    }

    func testNewMessagePillWhenScrolledUp() {
        launch(engine: "slow")
        for i in 1...6 {
            send("message \(i) with enough words to take up some room on screen")
            XCTAssertTrue(sendButton.waitForExistence(timeout: 30))
            XCTAssertTrue(element(containing: "Heard: message \(i)").waitForExistence(timeout: 30))
            let done = NSPredicate(format: "label CONTAINS 'limit '")
            expectation(for: done, evaluatedWith: element(containing: "Heard: message \(i)"))
            waitForExpectations(timeout: 30)
        }
        send("one more while I read back")
        // Scroll up by hand before the reply starts (the slow engine
        // waits 3 s before its first word).
        for _ in 0..<2 {
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            top.press(forDuration: 0.05, thenDragTo: lower)
        }
        XCTAssertFalse(element(containing: "You said: one more while I read back").isHittable,
                       "scrolled away from the bottom")
        let pill = app.buttons["Jump to new message"]
        XCTAssertTrue(pill.waitForExistence(timeout: 20), "pill when a reply lands off-screen")
        pill.tap()
        XCTAssertFalse(pill.waitForExistence(timeout: 2) && pill.isHittable, "pill clears at the bottom")
        XCTAssertTrue(element(containing: "Heard: one more while I read back").isHittable)
    }

    // MARK: - Persistence

    func testConversationSurvivesRelaunch() {
        launch()
        _ = sendAndWait("remember this after relaunch")
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(element(containing: "You said: remember this after relaunch").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Nod said: Heard: remember this after relaunch").exists)
    }

    func testStoppedTagSurvivesRelaunch() {
        launch(engine: "slow")
        send("talk for a while please")
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Nod said: Heard:").waitForExistence(timeout: 10))
        stopButton.tap()
        XCTAssertTrue(element(containing: "stopped").waitForExistence(timeout: 5))
        app.terminate()
        launch(engine: "slow", reset: false)
        XCTAssertTrue(element(containing: "Reply was stopped").waitForExistence(timeout: 10))
    }

    func testErrorRowSurvivesRelaunchAndStaysOutOfHistory() {
        launch(engine: "fail")
        send("fails before relaunch")
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
        app.terminate()
        launch(engine: "on", reset: false)
        XCTAssertTrue(element(containing: "Nod couldn't reply this time.").waitForExistence(timeout: 10))
        let label = sendAndWait("after relaunch")
        XCTAssertTrue(label.contains("(history 1,"), label)
    }

    // MARK: - Settings reach the engine

    func testReplyLengthSettingReachesEngine() {
        launch()
        openSettings()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Reply length'")).firstMatch.tap()
        app.buttons["Brief"].firstMatch.tap()
        closeSheet()
        let label = sendAndWait("short please")
        XCTAssertTrue(label.contains("limit 200)"), label)
    }

    func testAnythingElseReachesEngine() {
        launch()
        openSettings()
        let note = app.textViews["Anything else for Nod"].exists
            ? app.textViews["Anything else for Nod"] : app.textFields["Anything else for Nod"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("I work night shifts")
        closeSheet()
        let label = sendAndWait("hello")
        XCTAssertTrue(label.contains("About you: I work night shifts."), label)
    }

    func testSettingsPersistAcrossRelaunch() {
        launch()
        openSettings()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Approach'")).firstMatch.tap()
        app.buttons["Listen"].firstMatch.tap()
        let backup = app.switches.matching(NSPredicate(format: "label CONTAINS 'Back up'")).firstMatch
        scrollTo(backup)
        tapSwitch(backup)
        closeSheet()
        app.terminate()
        launch(reset: false)
        openSettings()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Approach' AND label CONTAINS 'Listen'")).firstMatch.exists
                      || app.staticTexts["Listen"].exists)
        let backupAfter = app.switches.matching(NSPredicate(format: "label CONTAINS 'Back up'")).firstMatch
        scrollTo(backupAfter)
        XCTAssertEqual(backupAfter.value as? String, "1")
    }

    func testThemeCanBeChangedBothWays() {
        launch()
        openSettings()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Theme'")).firstMatch.tap()
        app.buttons["Dark"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Theme' AND label CONTAINS 'Dark'")).firstMatch.waitForExistence(timeout: 3)
                      || app.staticTexts["Dark"].exists)
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Theme'")).firstMatch.tap()
        app.buttons["Light"].firstMatch.tap()
        closeSheet()
        XCTAssertTrue(app.buttons["I had a rough day"].waitForExistence(timeout: 5))
    }

    func testAdvancedSettingsRevealModelsAndDownloads() {
        launch()
        openSettings()
        let list = app.collectionViews.firstMatch
        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS 'advanced'")).firstMatch
        scrollTo(toggle, in: list)
        if (toggle.value as? String) == "1" { tapSwitch(toggle) }
        XCTAssertFalse(element(containing: "Qwen 3.5 4B").exists)
        tapSwitch(toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        list.swipeUp()
        let qwen = element(containing: "Qwen 3.5 4B")
        XCTAssertTrue(qwen.waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Apple Intelligence").exists)
        let cellular = element(containing: "Download over cellular")
        scrollTo(cellular, in: list)
        XCTAssertTrue(cellular.exists)
        // Turning it off hides them again.
        scrollTo(toggle, in: list)
        if !toggle.isHittable { list.swipeDown() }
        tapSwitch(toggle)
        XCTAssertFalse(element(containing: "Qwen 3.5 4B").waitForExistence(timeout: 2))
    }

    func testStartFreshClearsEverything() {
        launch()
        _ = sendAndWait("something to clear")
        openSettings()
        let fresh = app.buttons["Start fresh"]
        scrollTo(fresh)
        fresh.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS '2 messages'")).firstMatch.exists)
        app.alerts.buttons["Clear Conversation"].tap()
        XCTAssertTrue(app.buttons["I had a rough day"].waitForExistence(timeout: 10))
        XCTAssertFalse(element(containing: "You said: something to clear").exists)
    }

    func testStartFreshCancelKeepsConversation() {
        launch()
        _ = sendAndWait("keep me")
        openSettings()
        let fresh = app.buttons["Start fresh"]
        scrollTo(fresh)
        fresh.tap()
        app.alerts.buttons["Cancel"].tap()
        closeSheet()
        XCTAssertTrue(element(containing: "You said: keep me").exists)
    }

    // MARK: - Memory

    /// On Apple Intelligence the verbatim window is roomy: compression
    /// runs when a message arrives with 20 already waiting, so the 11th
    /// user message triggers it and the oldest 12 get a chapter note.
    func fillPastCompression() {
        _ = sendAndWait("my sister Leila is moving to Toronto in March")
        for i in 1...10 {
            _ = sendAndWait("filler number \(i) about the weather")
        }
    }

    func testMemoryEmptyStateFromHeader() {
        launch()
        app.buttons["What Nod remembers"].tap()
        XCTAssertTrue(element(containing: "They'll appear here").waitForExistence(timeout: 5))
        closeSheet()
    }

    func testMemoryNoteIsWrittenAndRecallWorks() {
        launch()
        fillPastCompression()
        app.buttons["What Nod remembers"].tap()
        let note = element(containing: "They said: my sister Leila")
        XCTAssertTrue(note.waitForExistence(timeout: 20), "chapter note written")
        XCTAssertTrue(element(containing: "In use now").exists)
        closeSheet()
        let label = sendAndWait("where is Leila moving again")
        XCTAssertTrue(label.contains("Remembered: my sister Leila is moving to Toronto in March."), label)
    }

    func testMemoryIsReachableFromSettings() {
        launch()
        openSettings()
        // The row inside the Settings sheet, not the header button behind it.
        app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH 'What Nod remembers'")).firstMatch.tap()
        XCTAssertTrue(element(containing: "They'll appear here").waitForExistence(timeout: 5))
    }

    func testForgettingANoteStopsRecall() {
        launch()
        fillPastCompression()
        app.buttons["What Nod remembers"].tap()
        XCTAssertTrue(element(containing: "They said: my sister Leila").waitForExistence(timeout: 20))
        app.buttons["Options for this note"].firstMatch.tap()
        app.buttons["Forget"].firstMatch.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Forget"].tap()
        XCTAssertTrue(element(containing: "They'll appear here").waitForExistence(timeout: 5))
        closeSheet()
        let label = sendAndWait("where is Leila moving again")
        XCTAssertFalse(label.contains("Remembered: my sister Leila"), label)
        // The messages themselves stay in the chat (scroll back to it:
        // rows far above the bottom aren't built until shown).
        let original = element(containing: "You said: my sister Leila")
        var swipes = 0
        while !original.exists && swipes < 20 {
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            top.press(forDuration: 0.05, thenDragTo: lower)
            swipes += 1
        }
        XCTAssertTrue(original.exists)
    }

    func testMemoryCountShowsInSettings() {
        launch()
        fillPastCompression()
        app.buttons["What Nod remembers"].tap()
        XCTAssertTrue(element(containing: "They said: my sister Leila").waitForExistence(timeout: 20))
        closeSheet()
        openSettings()
        XCTAssertTrue(element(containing: "1 note").waitForExistence(timeout: 5))
    }

    // MARK: - Onboarding and status

    func testOnboardingWithoutAppleIntelligence() {
        launch(engine: nil, extra: ["-nodAFM", "notSupported"])
        XCTAssertTrue(element(containing: "One-time download.").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download'")).firstMatch.exists)
        XCTAssertTrue(element(containing: "Everything stays on this iPhone.").exists)
    }

    func testOnboardingWithAppleIntelligenceOff() {
        launch(engine: nil, extra: ["-nodAFM", "disabled"])
        XCTAssertTrue(element(containing: "One quick step.").waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Or download Nod's own model instead").exists)
    }

    func testOnboardingOnUnsupportedPhone() {
        launch(engine: nil, extra: ["-nodAFM", "none"])
        XCTAssertTrue(element(containing: "Nod needs a newer iPhone.").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download'")).firstMatch.exists)
    }

    func testBannerWhenHistoryExistsButAppleIntelligenceDoesNot() {
        launch()
        _ = sendAndWait("before the restore")
        app.terminate()
        launch(engine: nil, reset: false, extra: ["-nodAFM", "notSupported"])
        XCTAssertTrue(element(containing: "Apple Intelligence isn't available on this iPhone.").waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "You said: before the restore").exists, "history stays visible")
        XCTAssertFalse(element(containing: "One-time download.").exists)
    }

    func testDownloadStatesShowTheRightActions() {
        let cases: [(String, String)] = [
            ("downloading", "Cancel"), ("wifi", "Use cellular this time"),
            ("paused", "Resume download"), ("failNetwork", "Try again"),
            ("failDisk", "Try again"), ("failOther", "Try again"),
        ]
        for (state, action) in cases {
            launch(engine: "on", extra: ["-nodDownload", state])
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), "\(state) → \(action)")
            app.terminate()
        }
    }

    func testCancellingADownloadAsksFirst() {
        launch(extra: ["-nodDownload", "downloading"])
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        let alert = app.alerts["Pause download?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["Keep downloading"].exists)
        XCTAssertTrue(alert.buttons["Pause"].exists)
        alert.buttons["Keep downloading"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 2))
    }

    /// Picks the downloadable model in advanced settings. With the
    /// scripted engine nothing is downloaded; only the preference moves.
    func chooseDownloadableModel() {
        openSettings()
        let list = app.collectionViews.firstMatch
        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS 'advanced'")).firstMatch
        scrollTo(toggle, in: list)
        if (toggle.value as? String) != "1" { tapSwitch(toggle) }
        list.swipeUp()
        let qwen = element(containing: "Qwen 3.5 4B")
        XCTAssertTrue(qwen.waitForExistence(timeout: 5))
        qwen.tap()
        closeSheet()
    }

    func testQuickCloseKeepsTheChosenModel() {
        launch()
        chooseDownloadableModel()
        // The person leaves the app, then it's closed (swiped away or
        // ended by iOS) within the first seconds of the launch.
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(element(containing: "Switched to Apple Intelligence").waitForExistence(timeout: 3),
                       "closing the app is not a crash")
    }

    func testCrashDuringLaunchFallsBackToAppleIntelligence() {
        launch()
        chooseDownloadableModel()
        // The next launch finds the previous one unfinished, as after a
        // crash: the breaker should fall back to Apple Intelligence.
        app.terminate()
        launch(reset: false, extra: ["-nodCrashedLastLaunch", "YES"])
        XCTAssertTrue(element(containing: "Switched to Apple Intelligence").waitForExistence(timeout: 10))
        app.buttons["Dismiss"].tap()
        XCTAssertFalse(element(containing: "Switched to Apple Intelligence").waitForExistence(timeout: 2))
    }

    func testLockScreenShowsUnlock() {
        launch(extra: ["-nodLocked", "YES"])
        XCTAssertTrue(element(containing: "Nod is locked.").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Unlock Nod"].exists)
    }

    func testFaceIDToggleTurnsOnAndOff() {
        launch()
        openSettings()
        let faceID = app.switches.matching(NSPredicate(format: "label CONTAINS 'Face ID'")).firstMatch
        XCTAssertTrue(faceID.waitForExistence(timeout: 5))
        scrollTo(faceID)
        XCTAssertEqual(faceID.value as? String, "0")
        tapSwitch(faceID)
        XCTAssertEqual(faceID.value as? String, "1")
        tapSwitch(faceID)
        XCTAssertEqual(faceID.value as? String, "0")
    }

    // MARK: - Accessibility

    func testLargestTextSizesKeepControlsReachable() {
        launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["I had a rough day"].waitForExistence(timeout: 5))
        XCTAssertTrue(sendButton.isHittable || sendButton.exists)
        XCTAssertTrue(app.buttons["Settings"].isHittable)
        _ = sendAndWait("big text")
    }
}
