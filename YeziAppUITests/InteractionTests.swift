import XCTest

final class InteractionTests: XCTestCase {
    @MainActor
    func testListeningQueueMiniPlayerAndAuditionRestore() {
        continueAfterFailure = false
        let app = launch("feed", emptyMoment: true)
        app.buttons["播放音乐列表"].tap()
        app.buttons["网站歌单"].tap()
        let playlist = app.buttons["listening.playlist.123456"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 10)); playlist.tap()
        XCTAssertTrue(app.staticTexts["共 217 首 · 已加载 50 首"].waitForExistence(timeout: 10))
        capture(app, name: "player-playlist-metadata")
        let song = app.buttons["listening.song.003OUlho2HcRHC"]
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        song.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["暂停播放"].waitForExistence(timeout: 10))
        let progress = app.sliders["播放进度"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: progress)
        waitForExpectations(timeout: 5)
        app.buttons["player.toggle"].tap()
        XCTAssertTrue(app.buttons["继续播放"].waitForExistence(timeout: 5))
        progress.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "0:(2[5-9]|3[0-5])")).firstMatch.waitForExistence(timeout: 5), "原生滑块手势应跳到曲目中段")
        app.buttons["上一首"].tap()
        XCTAssertTrue(app.staticTexts["0:00"].waitForExistence(timeout: 5))
        app.buttons["player.toggle"].tap()
        app.buttons["下一首"].tap()
        XCTAssertTrue(app.staticTexts["正在播放"].waitForExistence(timeout: 10))
        capture(app, name: "player-current-and-queue")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["待播放"].tap()
        XCTAssertTrue(app.buttons["收起待播放列表"].waitForExistence(timeout: 5))
        capture(app, name: "player-queue")
        app.buttons["收起待播放列表"].tap()
        XCTAssertFalse(app.buttons["listening.song.003OUlho2HcRHC"].exists)
        app.buttons["展开待播放列表"].tap()
        XCTAssertTrue(app.buttons["listening.song.003OUlho2HcRHC"].exists)
        app.buttons["listening.dismiss"].tap()
        XCTAssertTrue(app.buttons["player.mini"].waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(app.buttons["写絮语"].frame.maxY, app.buttons["player.mini"].frame.minY)
        capture(app, name: "player-mini-moments")
        app.tabBars.buttons["文章"].tap()
        XCTAssertTrue(app.buttons["player.mini"].waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(app.buttons["写文章"].frame.maxY, app.buttons["player.mini"].frame.minY)
        capture(app, name: "player-mini-articles")
        app.tabBars.buttons["絮语"].tap()
        XCTAssertTrue(app.buttons["写絮语"].waitForExistence(timeout: 5))
        app.buttons["写絮语"].tap()
        capture(app, name: "player-enter-composer")
        XCTAssertTrue(app.buttons["音乐"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["音乐"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["添加音乐"].waitForExistence(timeout: 5))
        let audition = app.buttons["music-picker.preview.003OUlho2HcRHC"]
        XCTAssertTrue(audition.waitForExistence(timeout: 5)); audition.tap()
        let playing = NSPredicate(format: "value == %@", "正在试听")
        expectation(for: playing, evaluatedWith: audition)
        waitForExpectations(timeout: 10)
        capture(app, name: "player-editor-audition")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.buttons["关闭编辑器"].waitForExistence(timeout: 5)); app.buttons["关闭编辑器"].tap()
        XCTAssertTrue(app.buttons["player.mini"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["暂停播放"].exists)
        app.buttons["player.mini"].tap()
        XCTAssertTrue(app.staticTexts["稻香"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["正在播放"].exists)
        capture(app, name: "player-restored-after-audition")
        app.terminate()
    }

    @MainActor
    func testPlayerDarkLargeText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        app.launch()
        XCTAssertTrue(app.buttons["播放音乐列表"].waitForExistence(timeout: 15)); app.buttons["播放音乐列表"].tap()
        let song = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "listening.song.")).firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 10)); song.tap()
        XCTAssertTrue(app.buttons["暂停播放"].waitForExistence(timeout: 10))
        capture(app, name: "player-dark-large")
        app.terminate()
    }
    @MainActor
    func testPaletteComparisons() {
        continueAfterFailure = false
        for palette in ["oat", "blue", "clay", "lilac"] {
            let app = XCUIApplication()
            app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-palette", palette]
            app.launch()
            XCTAssertTrue(app.buttons["moment-comments-101"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["写絮语"].waitForExistence(timeout: 5))
            capture(app, name: "palette-\(palette)-moments")
            app.tabBars.buttons["管理"].tap()
            XCTAssertTrue(app.buttons["在 App 内预览网站"].waitForExistence(timeout: 5))
            capture(app, name: "palette-\(palette)-management")
            app.terminate()
        }
    }
    @MainActor
    func testCommentsAndBackupsDarkLargeText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(app.buttons["更多絮语操作"].waitForExistence(timeout: 15))
        let comments = app.buttons["moment-comments-101"]
        for _ in 0..<6 where !comments.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.65)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)))
        }
        XCTAssertTrue(comments.exists)
        if comments.frame.midY > app.frame.height * 0.65 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.65)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)))
        }
        capture(app, name: "moment-dark-large-metadata")
        app.tabBars.buttons["管理"].tap()
        let backup = app.buttons["management.网站备份"]
        for _ in 0..<8 where !backup.isHittable { app.swipeUp() }
        XCTAssertTrue(backup.exists); backup.tap()
        XCTAssertTrue(app.staticTexts["完整加密备份已完成"].waitForExistence(timeout: 5))
        capture(app, name: "website-backups-dark-large")
    }
    @MainActor
    func testMomentInlineCommentsAndBackupManagement() {
        continueAfterFailure = false
        let app = launch("feed")
        XCTAssertTrue(app.buttons["更多絮语操作"].waitForExistence(timeout: 15))
        app.buttons["更多絮语操作"].tap()
        capture(app, name: "moment-menu-icons")
        app.buttons["全部"].tap()
        let comments = app.buttons["moment-comments-101"]
        for _ in 0..<3 where !comments.isHittable { app.swipeUp() }
        XCTAssertTrue(comments.waitForExistence(timeout: 5))
        if comments.frame.midY > app.frame.height * 0.65 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.65))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)))
        }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "郑州市")).firstMatch.exists)
        capture(app, name: "moment-location-tags")
        comments.tap()
        let reply = app.buttons["回复"].firstMatch
        for _ in 0..<4 where !reply.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)))
        }
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["山间来信"].exists)
        XCTAssertFalse(app.staticTexts["小满"].exists)
        capture(app, name: "moment-inline-comments")
        reply.tap()
        let input = app.textFields["回复评论"].exists ? app.textFields["回复评论"] : app.textViews["回复评论"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("Thank you")
        capture(app, name: "moment-inline-reply")
        app.buttons["发送回复"].tap()
        XCTAssertTrue(app.staticTexts["我的回复：Thank you"].waitForExistence(timeout: 5))
        app.tabBars.buttons["管理"].tap()
        let backup = app.buttons["management.网站备份"]
        for _ in 0..<5 where !backup.isHittable { app.swipeUp() }
        XCTAssertTrue(backup.exists); backup.tap()
        XCTAssertTrue(app.navigationBars["网站备份"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["完整加密备份已完成"].waitForExistence(timeout: 5))
        capture(app, name: "website-backups")
        app.buttons["恢复"].firstMatch.tap()
        XCTAssertTrue(app.buttons["确认恢复"].waitForExistence(timeout: 5))
        capture(app, name: "website-restore-confirmation")
        if app.buttons["取消"].exists { app.buttons["取消"].tap() }
        else { app.navigationBars["网站备份"].tap() }
    }
    @MainActor
    func testMistPaletteLargeText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(app.buttons["更多絮语操作"].waitForExistence(timeout: 15))
        capture(app, name: "mist-moments-large-text")
        app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(app.buttons["在 App 内预览网站"].waitForExistence(timeout: 5))
        capture(app, name: "mist-management-large-text")
    }

    @MainActor
    func testNativeDarkScreensAndScrollRecovery() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-empty-moment", "--preview-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["写絮语"].waitForExistence(timeout: 15))
        capture(app, name: "native-moments-dark")
        app.swipeUp()
        XCTAssertTrue(app.buttons["写絮语"].waitForExistence(timeout: 5))
        app.tabBars.buttons["文章"].tap()
        XCTAssertTrue(app.buttons["写文章"].waitForExistence(timeout: 5))
        capture(app, name: "native-articles-dark")
        app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(app.buttons["在 App 内预览网站"].waitForExistence(timeout: 5))
        capture(app, name: "native-management-dark")
    }

    @MainActor
    func testNativeRefreshScreensAndMediaMenus() {
        let app = launch("feed", emptyMoment: true)
        XCTAssertTrue(app.buttons["播放音乐列表"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["筛选絮语：全部"].exists)
        app.buttons["更多絮语操作"].tap()
        capture(app, name: "native-moment-filter-menu")
        app.buttons["照片"].tap()
        XCTAssertTrue(app.staticTexts["仅看照片"].waitForExistence(timeout: 5))
        app.buttons["更多絮语操作"].tap()
        app.buttons["全部"].tap()
        XCTAssertTrue(app.staticTexts["记录日常的片刻"].waitForExistence(timeout: 5))
        capture(app, name: "native-moments-light")
        app.buttons["播放音乐列表"].tap()
        XCTAssertTrue(app.navigationBars["听音乐"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["絮语正文"].exists)
        capture(app, name: "native-listening")
        app.buttons["网站歌单"].tap()
        XCTAssertTrue(app.staticTexts["散步的时候听"].waitForExistence(timeout: 5))
        capture(app, name: "native-playlists")
        app.buttons["listening.dismiss"].tap()
        app.tabBars.buttons["文章"].tap()
        XCTAssertTrue(app.buttons["筛选文章：全部"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "不必走得很远")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.staticTexts["随笔"].firstMatch.frame.width, 20)
        capture(app, name: "native-articles-light")
        app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(app.buttons["在 App 内预览网站"].waitForExistence(timeout: 5))
        capture(app, name: "native-management-light")
        app.tabBars.buttons["絮语"].tap()
        app.buttons["写絮语"].tap()
        XCTAssertTrue(app.buttons["图片"].waitForExistence(timeout: 5))
        app.buttons["图片"].tap()
        XCTAssertTrue(app.buttons["image-option.拍照"].waitForExistence(timeout: 5))
        capture(app, name: "native-image-menu")
        app.buttons["取消"].firstMatch.tap()
        app.buttons["视频"].tap()
        XCTAssertTrue(app.navigationBars["插入视频"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["从相册选择视频"].exists)
        capture(app, name: "native-video-menu")
        let link = app.textFields["https://"]
        link.tap()
        link.typeText("https://example.com/video.mp4")
        app.buttons["插入链接"].tap()
        let body = app.textViews["絮语正文"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue((body.value as? String ?? "").contains("!video https://example.com/video.mp4"))
    }

    @MainActor
    func testReportedDarkScreensAndUnobstructedComposeButton() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-empty-moment", "--preview-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["写絮语"].waitForExistence(timeout: 15))
        capture(app, name: "review-dark-feed")
        for _ in 0..<5 { app.swipeUp() }
        guard let song = app.staticTexts.matching(identifier: "晴天").allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("列表末尾的音乐应完整可见")
            return
        }
        XCTAssertLessThan(song.frame.maxY, app.buttons["写絮语"].frame.minY)
        capture(app, name: "review-dark-feed-bottom")
        app.tabBars.buttons["文章"].tap()
        XCTAssertTrue(app.buttons["写文章"].waitForExistence(timeout: 5))
        capture(app, name: "review-dark-articles")
        app.tabBars.buttons["评论"].tap()
        let source = app.staticTexts["时间过得真快，好想停滞到那一刻。"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "!music qqvip:")).firstMatch.exists)
        capture(app, name: "review-dark-comments")
        app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(app.buttons["management.文件管理"].waitForExistence(timeout: 5))
        capture(app, name: "review-dark-management")
    }

    @MainActor
    func testAIImageMenuGenerationAndInsertionAtCursor() {
        let app = launch("article")
        let body = app.textViews["文章正文"]
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        let original = body.value as? String ?? ""
        app.buttons["article.tool.图片"].tap()
        let ai = app.buttons["image-option.AI 生图"]
        let photos = app.buttons["image-option.插入图片"]
        XCTAssertTrue(ai.waitForExistence(timeout: 5))
        XCTAssertLessThan(ai.frame.midY, photos.frame.midY)
        capture(app, name: "editorial-add-image")
        ai.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["AI 生图"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ai-image.insert"].isEnabled)
        app.buttons["服务设置"].tap()
        XCTAssertTrue(app.navigationBars["生图服务"].waitForExistence(timeout: 5))
        capture(app, name: "editorial-ai-image-settings-offline")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["AI 生图"].waitForExistence(timeout: 5))
        let prompt = app.textFields["ai-image.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tap()
        prompt.typeText("Afternoon light and leaf shadows")
        app.buttons["ai-image.generate"].tap()
        XCTAssertTrue(app.images["AI 生成图片"].waitForExistence(timeout: 15))
        app.switches["同时设为文章封面"].tap()
        capture(app, name: "editorial-ai-image-preview-offline")
        XCTAssertTrue(app.buttons["ai-image.insert"].isEnabled)
        app.buttons["ai-image.insert"].tap()
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "![AI 配图]"), object: body)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 15), .completed)
        let text = body.value as? String ?? ""
        XCTAssertTrue(text.contains(original))
        XCTAssertEqual(text.components(separatedBy: "![AI 配图]").count - 1, 1)
        XCTAssertTrue(text.contains("/uploads/local-preview.jpg"))
        app.buttons["article.options"].tap()
        app.buttons["发布设置"].tap()
        XCTAssertTrue(app.navigationBars["发布设置"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["可选图片地址"].value as? String, "/uploads/local-preview.jpg")
    }

    @MainActor
    func testArticleCompactToolbarPreservesWritingAndPreview() {
        let app = launch("article")
        let body = app.textViews["文章正文"]
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        let tools = ["加粗", "标题", "链接", "列表", "图片", "音乐", "预览"].map { app.buttons["article.tool.\($0)"] }
        for tool in tools {
            XCTAssertTrue(tool.isHittable)
            XCTAssertGreaterThanOrEqual(tool.frame.width, 44)
            XCTAssertEqual(tool.frame.midY, tools[0].frame.midY, accuracy: 1)
        }
        XCTAssertFalse(app.segmentedControls["写作模式"].exists)
        capture(app, name: "editorial-editor-compact")

        let original = body.value as? String
        tools[0].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue((body.value as? String)?.contains("**加粗文字**") == true)
        for tool in tools { XCTAssertTrue(tool.isHittable, "键盘上方仍能使用所有工具") }
        capture(app, name: "editorial-editor-keyboard")
        app.buttons["article.options"].tap()
        app.buttons["撤销"].tap()
        XCTAssertEqual(body.value as? String, original)

        tools[2].tap()
        XCTAssertTrue((body.value as? String)?.contains("[链接文字](https://)") == true)
        let withLink = body.value as? String
        tools[6].tap()
        XCTAssertTrue(app.navigationBars["Markdown 预览"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(body.value as? String, withLink)
        tools[3].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue((body.value as? String)?.contains("- ") == true)
        app.typeText("Still writing")
        XCTAssertTrue((body.value as? String)?.contains("Still writing") == true)
    }

    @MainActor
    func testEditorialScreensAndNavigation() {
        let app = launch("feed", emptyMoment: true)
        XCTAssertTrue(app.tabBars.buttons["管理"].waitForExistence(timeout: 15))
        capture(app, name: "editorial-feed")
        app.tabBars.buttons["文章"].tap()
        XCTAssertTrue(app.buttons["写文章"].waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(app.buttons["写文章"].frame.maxY, app.tabBars.buttons["文章"].frame.minY, "写文章按钮不能被底栏遮住")
        capture(app, name: "editorial-articles")
        app.tabBars.buttons["评论"].tap()
        XCTAssertTrue(app.staticTexts["小满"].waitForExistence(timeout: 5))
        capture(app, name: "editorial-comments")
        app.tabBars.buttons["管理"].tap()
        let files = app.buttons["management.文件管理"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        capture(app, name: "editorial-management")
        files.tap()
        XCTAssertTrue(app.navigationBars["文件管理"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["管理"].isHittable, "子页面应收起底栏")
        app.buttons["图片"].firstMatch.tap()
        XCTAssertTrue(app.buttons["上传文件"].exists)
        capture(app, name: "editorial-files")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["管理"].waitForExistence(timeout: 5))
        let settings = app.buttons["management.基础信息"]
        for _ in 0..<4 { if settings.isHittable { break }; app.swipeUp() }
        settings.tap()
        XCTAssertTrue(app.textFields["站点名称"].waitForExistence(timeout: 5))
        capture(app, name: "editorial-settings")
        app.terminate()
        let editor = launch("article")
        XCTAssertTrue(editor.textViews["文章正文"].waitForExistence(timeout: 15))
        capture(editor, name: "editorial-editor")
    }

    @MainActor
    func testNativeSwipeActionsAndLabeledComposeButtons() {
        let app = launch("feed", emptyMoment: true)
        XCTAssertTrue(app.buttons["写絮语"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["编辑絮语"].exists)
        let moment = app.cells.element(boundBy: 1)
        XCTAssertTrue(moment.waitForExistence(timeout: 5))
        moment.swipeLeft()
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["删除"].exists)
        capture(app, name: "native-moment-swipe")

        app.tabBars.buttons["文章"].tap()
        XCTAssertTrue(app.buttons["写文章"].waitForExistence(timeout: 5))
        let article = app.cells.element(boundBy: 1)
        XCTAssertTrue(article.waitForExistence(timeout: 5))
        article.swipeLeft()
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["删除"].exists)
        capture(app, name: "native-article-swipe")
    }

    @MainActor
    func testEditorialSecondaryScreens() {
        for (screen, title) in [("music-settings", "音乐设置"), ("appearance", "外观主题"), ("updates", "GitHub 更新"), ("works", "作品"), ("taxonomy", "分类与标签"), ("references", "引用管理"), ("about", "关于页面")] {
            let app = launch(screen)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15))
            XCTAssertFalse(app.tabBars.buttons["管理"].isHittable)
            capture(app, name: "editorial-" + screen)
            app.terminate()
        }
    }

    @MainActor
    func testEditorialLargeTypeAndDarkMode() {
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "manage", "--ui-testing", "--preview-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        app.launch()
        XCTAssertTrue(app.buttons["management.文件管理"].waitForExistence(timeout: 15))
        capture(app, name: "editorial-dark-large-type")
        app.buttons["management.文件管理"].tap()
        XCTAssertTrue(app.buttons["上传文件"].waitForExistence(timeout: 5))
        capture(app, name: "editorial-files-large-type")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
        XCTAssertTrue(app.buttons["写絮语"].waitForExistence(timeout: 15))
        app.buttons["写絮语"].tap()
        app.buttons["音乐"].firstMatch.tap()
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
    func testSearchPreviewFailureExplainsServiceStatusAndStillAllowsAdding() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-empty-moment", "--preview-music-unavailable"]
        app.launch()
        XCTAssertTrue(app.buttons["写絮语"].waitForExistence(timeout: 15))
        app.buttons["写絮语"].tap()
        app.buttons["音乐"].firstMatch.tap()
        let search = app.textFields["搜索歌曲名或歌手"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("sun\n")
        let preview = app.buttons["music-picker.preview.003OUlho2HcRHC"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        let notice = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "探测歌曲未返回播放地址")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["添加这首音乐"].isEnabled)
        XCTAssertTrue(app.navigationBars["添加音乐"].exists)
        app.buttons["music-picker.select.003OUlho2HcRHC"].tap()
        XCTAssertTrue(app.buttons["添加这首音乐"].isEnabled)
        app.buttons["添加这首音乐"].tap()
        XCTAssertTrue(app.textViews["絮语正文"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testManagementRowsAcceptTapsBetweenTextAndChevron() {
        for (title, destination) in [("草稿箱", "草稿箱"), ("分类与标签", "分类与标签"), ("引用资料", "引用管理"), ("作品", "作品"), ("关于页面", "关于页面"), ("站点概览", "概览")] {
            let app = launch("manage")
            let row = app.buttons["management.\(title)"]
            for _ in 0..<5 {
                if row.exists && row.isHittable && row.frame.maxY < app.tabBars.buttons["管理"].frame.minY { break }
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
            for _ in 0..<5 {
                if card.exists && card.isHittable && card.frame.maxY < app.tabBars.buttons["管理"].frame.minY { break }
                app.swipeUp()
            }
            XCTAssertTrue(card.waitForExistence(timeout: 15))
            for _ in 0..<3 {
                if card.isHittable && card.frame.maxY < app.tabBars.buttons["管理"].frame.minY { break }
                app.swipeUp()
            }
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
            XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 5), "点击 \(title) 卡片的边距应进入页面")
            app.terminate()
        }
    }
}
