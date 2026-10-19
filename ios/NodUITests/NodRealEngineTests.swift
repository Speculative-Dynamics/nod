// NodRealEngineTests.swift
// End-to-end tests against the real reply engines: no scripted engine.
// They need hardware that can run the models (an iPhone with Apple
// Intelligence, or "My Mac (Designed for iPad)" on Apple silicon), so
// they're opt-in:
//
//   TEST_RUNNER_NOD_REAL_ENGINE=1 xcodebuild test -scheme Nod \
//     -destination 'platform=macOS,arch=arm64,variant=Designed for [iPad,iPhone]' \
//     -only-testing:NodUITests/NodRealEngineTests
//
// TEST_RUNNER_NOD_REAL_MLX=1 also runs the Qwen download test (~3 GB).
//
// Every test starts with `-nodReset YES`, which wipes the app's
// conversation. Don't point these at a phone whose Nod data matters.

import XCTest

final class NodRealEngineTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOD_REAL_ENGINE"] == "1",
                          "Set TEST_RUNNER_NOD_REAL_ENGINE=1 to run real-engine tests")
    }

    override func tearDown() {
        if let app, app.state == .runningForeground {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "end state"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    func launch(reset: Bool = true) {
        let app = XCUIApplication()
        app.launchArguments = ["-nodSkipSplash", "YES"] + (reset ? ["-nodReset", "YES"] : [])
        app.launch()
        self.app = app
    }

    var messageField: XCUIElement {
        let view = app.textViews["Message"]
        return view.exists ? view : app.textFields["Message"]
    }

    func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Sends a message and waits until the reply has finished (the send
    /// button is back). Returns the last Nod reply's text.
    @discardableResult
    func sendAndWait(_ text: String, timeout: TimeInterval = 120) -> String {
        XCTAssertTrue(messageField.waitForExistence(timeout: 20))
        messageField.tap()
        messageField.typeText(text)
        app.buttons["Send message"].tap()
        let stop = app.buttons["Stop response"]
        _ = stop.waitForExistence(timeout: 10)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: stop)
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(element(containing: "Nod couldn't reply").exists, "reply failed for: \(text)")
        let replies = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Nod said: '"))
        XCTAssertGreaterThan(replies.count, 0)
        let label = replies.element(boundBy: replies.count - 1).label
        return String(label.dropFirst("Nod said: ".count))
    }

    // MARK: - Apple Intelligence

    func testAppleIntelligenceReplies() {
        launch()
        let reply = sendAndWait("I had a long day at work and I'm tired")
        XCTAssertGreaterThan(reply.count, 10, reply)
        let second = sendAndWait("my manager kept adding things to my list")
        XCTAssertGreaterThan(second.count, 10, second)
    }

    func testStopEndsARealReply() {
        launch()
        messageField.tap()
        messageField.typeText("Tell me, in a lot of detail, what you think about long weekends and why people need them")
        app.buttons["Send message"].tap()
        let stop = app.buttons["Stop response"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        XCTAssertTrue(app.buttons["Send message"].waitForExistence(timeout: 10))
    }

    func testRealMemoryNoteAndRecall() {
        launch()
        sendAndWait("my sister Leila is moving to Toronto in March and I'm kind of gutted")
        sendAndWait("we've lived ten minutes apart our whole adult lives")
        sendAndWait("anyway work was busy today")
        sendAndWait("my manager Priya keeps messaging me late at night")
        sendAndWait("I answer every time, I don't know how not to")
        sendAndWait("I think I need to sleep more")
        sendAndWait("the coffee machine at work broke today")
        sendAndWait("I tried a new lunch place, it was fine")
        sendAndWait("the train was late again this morning")
        sendAndWait("my plants are finally growing")
        sendAndWait("I watched half a movie and fell asleep")
        // Apple Intelligence keeps 20 messages verbatim; the 11th user
        // message compresses the oldest 12 into a chapter note.
        app.buttons["What Nod remembers"].tap()
        XCTAssertTrue(element(containing: "In use now").waitForExistence(timeout: 120), "a note was written")
        app.buttons["Done"].firstMatch.tap()
        let reply = sendAndWait("wait, where is my sister moving again?")
        XCTAssertTrue(reply.localizedCaseInsensitiveContains("Toronto"), "recall: \(reply)")
    }

    // MARK: - Downloadable model

    func testQwenDownloadsAndReplies() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOD_REAL_MLX"] == "1",
                          "Set TEST_RUNNER_NOD_REAL_MLX=1 to download Qwen (~3 GB)")
        launch()
        app.buttons["Settings"].tap()
        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS 'advanced'")).firstMatch
        var swipes = 0
        while !toggle.isHittable && swipes < 8 { app.collectionViews.firstMatch.swipeUp(); swipes += 1 }
        if (toggle.value as? String) != "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        // Wi-Fi only: never turn on cellular downloads on someone's phone.
        element(containing: "Qwen 3.5 4B").tap()
        app.buttons["Done"].firstMatch.tap()
        // Download (~3 GB) then load. First wait for the readiness card
        // to appear, then for it to go away (the model is loaded).
        func busy() -> Bool {
            ["Getting Nod ready", "Waking Nod up", "Waiting for", "Download paused"]
                .contains { element(containing: $0).exists }
        }
        func failed() -> Bool {
            element(containing: "Couldn't download").exists
                || element(containing: "Nod couldn't start").exists
                || element(containing: "Not enough space").exists
        }
        let appeared = Date().addingTimeInterval(60)
        while !busy() && Date() < appeared && !failed() { sleep(1) }
        let deadline = Date().addingTimeInterval(2400)
        while busy() && Date() < deadline {
            XCTAssertFalse(failed(), "download or load failed")
            if failed() { return }
            sleep(10)
        }
        XCTAssertFalse(failed(), "download or load failed")
        XCTAssertFalse(busy(), "still downloading after 40 min")
        XCTAssertTrue(app.buttons["Send message"].waitForExistence(timeout: 30))
        let reply = sendAndWait("I had a rough day", timeout: 300)
        XCTAssertGreaterThan(reply.count, 10, reply)
    }
}
