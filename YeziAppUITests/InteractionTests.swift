import XCTest

final class InteractionTests: XCTestCase {
    @MainActor
    private func launch(_ screen: String, emptyMoment: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", screen, "--ui-testing"]
        if emptyMoment { app.launchArguments.append("--preview-empty-moment") }
        app.launch()
        return app
    }

    @MainActor
    func testCanWriteAcrossEmptyCanvasAfterSelectingMusic() {
        let app = launch("feed", emptyMoment: true)
        let shareMusic = app.buttons["分享音乐"]
        XCTAssertTrue(shareMusic.waitForExistence(timeout: 15))
        shareMusic.tap()
        let song = app.staticTexts["稻香"].firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 10))
        song.tap()
        app.buttons["添加这首音乐"].tap()

        let body = app.textViews["絮语正文"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(body.frame.height, 180, "可见书写留白必须属于真正的输入控件")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "选完音乐应回到正文输入")
        body.typeText("Music and words")
        XCTAssertEqual(body.value as? String, "Music and words")

        // Cancel another picker to dismiss the keyboard, then tap the empty lower area.
        app.buttons["音乐"].firstMatch.tap()
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let keyboardHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed)
        body.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 80, dy: 140)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText(" after music")
        XCTAssertEqual(body.value as? String, "Music and words after music")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "音乐选择后点击正文留白并继续输入"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testManagementRowsAcceptTapsBetweenTextAndChevron() {
        for (title, destination) in [("草稿箱", "草稿箱"), ("分类与标签", "分类与标签"), ("引用资料", "引用管理"), ("作品", "作品"), ("关于页面", "关于页面"), ("站点概览", "概览")] {
            let app = launch("manage")
            let row = app.buttons["management.\(title)"]
            for _ in 0..<5 {
                if row.exists && row.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(row.isHittable, title)
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5)).tap()
            XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 5), "点击 \(title) 的留白应进入页面")
            app.terminate()
        }
    }

    @MainActor
    func testManagementCardsAcceptTapsOnPadding() {
        for (title, destination) in [("文件管理", "文件管理"), ("基础信息", "基础信息"), ("音乐", "音乐设置"), ("外观", "外观主题"), ("GitHub 更新", "GitHub 更新")] {
            let app = launch("manage")
            let card = app.buttons["management.\(title)"]
            XCTAssertTrue(card.waitForExistence(timeout: 15))
            for _ in 0..<3 {
                if card.isHittable { break }
                app.swipeUp()
            }
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
            XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 5), "点击 \(title) 卡片的边距应进入页面")
            app.terminate()
        }
    }
}
