import XCTest

final class InteractionTests: XCTestCase {
    @MainActor
    func testCommentNotificationOpensReplyForItsTarget() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-push-comment"]
        app.launch()
        XCTAssertTrue(app.navigationBars["回复评论"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["保存回复"].exists)
    }
    @MainActor
    func testMusicNotificationOpensMusicSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-push-music"]
        app.launch()
        XCTAssertTrue(app.navigationBars["音乐设置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["关闭"].exists)
    }
    @MainActor
    func testNotificationSettingsUsesNativeControlsWithoutRequestingPermissionInPreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "manage", "--ui-testing"]
        app.launch()
        let row = app.buttons["management.通知"]
        for _ in 0..<5 { if row.exists && row.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.navigationBars["通知"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["新评论"].exists)
        XCTAssertTrue(app.switches["QQ 音乐登录失效"].exists)
        app.buttons["notifications.enable"].tap()
        XCTAssertTrue(app.staticTexts["预览模式不申请系统权限，也不发送推送。"].waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "notification-settings"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor
    func testEmbeddedPlaylistDisplaysSongsAndSwipesWithoutStartingPlayback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "reader", "--ui-testing", "--preview-reader-playlist"]
        app.launch()
        let first = app.buttons["embedded.playlist.song.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(first.label.contains("晴天"))
        XCTAssertTrue(first.label.contains("周杰伦"))
        XCTAssertFalse(app.buttons["播放视频"].exists)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).press(forDuration: 0.05, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let second = app.buttons["embedded.playlist.song.1"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(second.label.contains("稻香"))
        XCTAssertTrue(second.label.contains("等 217 首"))
        let mode = app.buttons["embedded.playlist.mode"]
        let play = app.buttons["embedded.playlist.toggle"]
        XCTAssertLessThanOrEqual(mode.frame.maxX, play.frame.minX + 1)
        XCTAssertEqual(mode.label, "顺序播放")
        mode.tap()
        XCTAssertEqual(mode.label, "随机播放")
        mode.tap()
        XCTAssertEqual(mode.label, "顺序播放")
        XCTAssertFalse(app.buttons["player.mini"].exists)
        capture(app, name: "embedded-playlist-and-video")
        second.tap()
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).press(forDuration: 0.05, thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(app.buttons["player.mini"].waitForExistence(timeout: 5))
        app.buttons["player.mini"].tap()
        XCTAssertTrue(app.buttons["player.toggle"].waitForExistence(timeout: 5))
        capture(app, name: "embedded-playlist-controls")
        app.terminate()
    }

    @MainActor
    func testEmbeddedRandomPlaylistPreparesMetadataWithoutAudioAutoplay() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "reader", "--ui-testing", "--preview-reader-playlist", "--preview-playlist-random"]
        app.launch()
        let randomLabel = app.buttons["embedded.playlist.mode"]
        XCTAssertTrue(randomLabel.waitForExistence(timeout: 15))
        XCTAssertEqual(randomLabel.label, "随机播放")
        XCTAssertFalse(app.buttons["player.mini"].exists)
        capture(app, name: "embedded-random-playlist")
        app.terminate()
    }

    @MainActor
    func testPlayingLyricsReplaceCardArtistAndFoldedTitle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-lyric-cards", "--preview-empty-moment"]
        app.launch()
        let inline = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "music.inline.")).firstMatch
        XCTAssertTrue(inline.waitForExistence(timeout: 15))
        XCTAssertTrue(inline.label.contains("晴天"))
        capture(app, name: "folded-music-vertically-centered")
        inline.tap()
        let playing = NSPredicate(format: "label CONTAINS %@", "歌词")
        expectation(for: playing, evaluatedWith: inline)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(inline.label.contains("周杰伦"))
        let secondary = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "music.secondary.")).firstMatch
        XCTAssertTrue(secondary.label.contains("歌词") || secondary.label.contains("慢下来"))
        let mini = app.buttons["player.mini"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        let lyricWidth = mini.frame.width
        capture(app, name: "lyrics-card-inline-mini")
        inline.tap()
        XCTAssertTrue(inline.label.contains("晴天"))
        XCTAssertEqual(secondary.label, "周杰伦")
        XCTAssertEqual(mini.frame.width, lyricWidth, accuracy: 1, "暂停回退歌手时保持整首歌的参考宽度")
        XCTAssertLessThan(mini.frame.width, 190, "短歌名和歌手不应撑满播放器最大宽度")
        XCTAssertLessThan(mini.frame.maxX, app.buttons["写絮语"].frame.minX)
        capture(app, name: "mini-player-content-width")
        mini.tap()
        let lyrics = app.buttons["player.lyrics.toggle"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap()
        XCTAssertEqual(lyrics.label, "收起歌词")
        capture(app, name: "compact-player-expanded-lyrics")
        app.sliders["播放进度"].adjust(toNormalizedSliderPosition: 0.55)
        app.buttons["player.toggle"].tap()
        app.buttons["收起"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value CONTAINS %@", "在半程也能同步定位"), evaluatedWith: mini)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(mini.frame.width, lyricWidth, accuracy: 1, "切换到较长歌词时卡片不伸缩")
        capture(app, name: "mini-player-third-lyric-fixed-width")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(mini.frame.width, lyricWidth, accuracy: 1, "超长歌词滚动时卡片不伸缩")
        capture(app, name: "mini-player-overflow-scrolling")
        app.terminate()
    }

    @MainActor
    func testMiniPlayerAcrossReaderManagementAndSearch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-lyric-cards"]
        app.launch()
        let inline = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "music.inline.")).firstMatch
        XCTAssertTrue(inline.waitForExistence(timeout: 15)); inline.tap()
        let mini = app.buttons["player.mini"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        app.buttons["搜索絮语"].tap()
        XCTAssertTrue(mini.waitForNonExistence(timeout: 5))
        app.buttons["搜索絮语"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        app.tabBars.buttons["随笔"].tap()
        let article = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "在日常里，找一点风景")).firstMatch
        XCTAssertTrue(article.waitForExistence(timeout: 5)); article.tap()
        XCTAssertTrue(app.staticTexts["reader.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        capture(app, name: "global-mini-reader")
        app.buttons["关闭"].firstMatch.tap()
        app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        app.buttons["management.基础信息"].tap()
        XCTAssertTrue(app.navigationBars["基础信息"].waitForExistence(timeout: 5))
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        app.swipeUp(velocity: .slow)
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        capture(app, name: "global-mini-management")
        app.terminate()
    }

    @MainActor
    func testAboutPlaceholderHidesOnFocusWithoutSavingAndAppearanceHasNoLayoutPicker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "about", "--ui-testing", "--preview-empty-about"]
        app.launch()
        let placeholder = app.staticTexts["写下你的介绍、联系方式和站点说明…"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["支持 Markdown，选中文字即可排版。"].exists)
        app.textViews["关于页面正文"].tap()
        XCTAssertTrue(placeholder.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["支持 Markdown，选中文字即可排版。"].exists)
        XCTAssertFalse(app.buttons["保存页面"].isEnabled)
        capture(app, name: "loading-about-focused")
        app.terminate()
        app.launchArguments = ["--creation-preview", "--preview-screen", "appearance", "--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["配色方案"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["版式主题"].exists)
        XCTAssertFalse(app.buttons["经典版"].exists)
        capture(app, name: "loading-appearance")
        app.terminate()
    }

    @MainActor
    func testMomentPaginationLoadsByScrollingAndManagementKeepsIdentity() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-pagination"]
        app.launch()
        XCTAssertTrue(app.buttons["播放音乐列表"].waitForExistence(timeout: 15))
        for _ in 0..<10 {
            if app.staticTexts["自动续载成功 1"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["自动续载成功 1"].exists)
        XCTAssertFalse(app.buttons["加载更多絮语"].exists)
        capture(app, name: "loading-auto-pagination")
        app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(app.staticTexts["叶子的小站"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.staticTexts["管理"].exists)
        app.tabBars.buttons["絮语"].tap()
        app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(app.staticTexts["叶子的小站"].exists)
        XCTAssertFalse(app.staticTexts["我的小站"].exists)
        capture(app, name: "loading-management-cached")
        app.tabBars.buttons["随笔"].tap()
        XCTAssertTrue(app.staticTexts["随笔与杂记 · 共 2 篇"].waitForExistence(timeout: 5))
        capture(app, name: "loading-essays")
        app.terminate()
    }

    @MainActor
    func testCommentFiltersSupportHorizontalSwipes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "comments", "--ui-testing"]
        app.launch()
        XCTAssertTrue(app.segmentedControls.firstMatch.waitForExistence(timeout: 15))
        let pending = app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "待审核")).firstMatch
        let approved = app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "已通过")).firstMatch
        XCTAssertTrue(pending.isSelected)
        app.swipeLeft()
        XCTAssertTrue(approved.isSelected)
        app.swipeRight()
        XCTAssertTrue(pending.isSelected)
        capture(app, name: "loading-comments-swiped")
        app.terminate()
    }

    @MainActor
    func testReaderMediaCodeAndNativeShare() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "reader", "--ui-testing", "--preview-reader-media"]
        app.launch()
        XCTAssertTrue(app.staticTexts["reader.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["reader.share"].isEnabled)
        capture(app, name: "confirmed-reader-media")
        let expand = app.buttons["reader.code.expand"]
        for _ in 0..<8 { if expand.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        capture(app, name: "confirmed-code-collapsed")
        expand.tap()
        XCTAssertTrue(app.buttons["收起代码"].waitForExistence(timeout: 5))
        capture(app, name: "confirmed-code-expanded")
        app.buttons["reader.share"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 5) || app.cells["拷贝"].waitForExistence(timeout: 2))
        capture(app, name: "confirmed-native-share")
        app.terminate()
    }

    @MainActor
    func testAudioFailureRetryDoesNotTerminateApp() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-network-audio-failure"]
        app.launch()
        XCTAssertTrue(app.buttons["播放音乐列表"].waitForExistence(timeout: 15))
        app.buttons["播放音乐列表"].tap()
        let song = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "listening.song.")).firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 10)); song.tap()
        let failure = app.staticTexts["音频无法播放，请重试。"]
        XCTAssertTrue(failure.waitForExistence(timeout: 20))
        app.buttons["重试"].firstMatch.tap()
        XCTAssertTrue(failure.waitForExistence(timeout: 20))
        XCTAssertEqual(app.state, .runningForeground)
        capture(app, name: "confirmed-audio-error-retry")
        app.terminate()
    }

    @MainActor
    func testVideoSharedTextRequiresChoiceAndInsertsCanonicalBV() {
        let app = launch("feed", emptyMoment: true)
        app.buttons["写絮语"].tap()
        XCTAssertTrue(app.buttons["视频"].waitForExistence(timeout: 5)); app.buttons["视频"].tap()
        let input = app.textFields["video.input"].exists ? app.textFields["video.input"] : app.textViews["video.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("分享 BV1xx411c7mD 以及 https://youtu.be/dQw4w9WgXcQ")
        XCTAssertFalse(app.buttons["确认插入"].isEnabled)
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "bilibili:BV1xx411c7mD")).firstMatch.tap()
        XCTAssertTrue(app.buttons["确认插入"].isEnabled)
        capture(app, name: "confirmed-video-share-choice")
        app.buttons["确认插入"].tap()
        let body = app.textViews["絮语正文"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue((body.value as? String ?? "").contains("!video bilibili:BV1xx411c7mD"))
        app.terminate()
    }

    @MainActor
    func testLyricsFollowPlaybackAndSeek() {
        continueAfterFailure = false
        let app = launch("feed")
        app.buttons["播放音乐列表"].tap()
        let song = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "listening.song.")).firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 10)); song.tap()
        let lyrics = app.buttons["player.lyrics.toggle"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 10)); lyrics.tap()
        XCTAssertTrue(app.scrollViews["player.lyrics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["留一点时间听音乐"].waitForExistence(timeout: 10))
        capture(app, name: "confirmed-player-lyrics")
        app.buttons["player.toggle"].tap()
        let progress = app.sliders["播放进度"]
        progress.adjust(toNormalizedSliderPosition: 0.55)
        XCTAssertEqual(lyrics.label, "收起歌词")
        XCTAssertLessThan(app.buttons["player.toggle"].frame.maxY, progress.frame.minY)
        lyrics.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "在半程也能同步定位"), evaluatedWith: lyrics)
        waitForExpectations(timeout: 5)
        capture(app, name: "confirmed-lyrics-seek")
        app.terminate()
    }

    @MainActor
    func testContentTypographyScreens() {
        continueAfterFailure = false
        let articles = launch("articles")
        XCTAssertTrue(articles.buttons["更多随笔操作"].waitForExistence(timeout: 15))
        XCTAssertTrue(articles.staticTexts["在日常里，找一点风景"].firstMatch.waitForExistence(timeout: 5))
        capture(articles, name: "typography-articles")
        articles.terminate()
        let comments = launch("comments")
        XCTAssertTrue(comments.staticTexts["给平凡的一天添一点颜色，真好。"].waitForExistence(timeout: 15))
        capture(comments, name: "typography-comments")
        comments.terminate()
        let reader = launch("reader")
        let metadata = reader.staticTexts["reader.metadata"]
        XCTAssertTrue(metadata.waitForExistence(timeout: 15))
        XCTAssertTrue(metadata.label.hasPrefix("随笔  ·  "))
        XCTAssertTrue(metadata.label.hasSuffix("#日常"))
        capture(reader, name: "typography-reader")
        reader.terminate()
        let about = launch("about")
        let body = about.textViews["关于页面正文"]
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        capture(about, name: "typography-about")
        body.tap()
        body.typeText("中英混排 Swift 123 🌿 𠮷")
        XCTAssertTrue((body.value as? String ?? "").contains("中英混排 Swift 123 🌿 𠮷"))
        capture(about, name: "typography-writing")
        about.buttons["about.tool.预览"].tap()
        XCTAssertTrue(about.navigationBars["Markdown 预览"].waitForExistence(timeout: 5))
        capture(about, name: "typography-preview")
        about.buttons["关闭"].tap()
        XCTAssertTrue((body.value as? String ?? "").contains("中英混排 Swift 123 🌿 𠮷"))
    }

    @MainActor
    func testGallerySwipeDownDismissAndShortDragRecovery() {
        let app = launch("feed", emptyMoment: true)
        XCTAssertTrue(app.buttons["moment.101.image.1"].waitForExistence(timeout: 15))
        app.buttons["moment.101.image.1"].tap()
        XCTAssertTrue(app.navigationBars["2 / 2"].waitForExistence(timeout: 5))
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let shortDrag = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        middle.press(forDuration: 0.05, thenDragTo: shortDrag, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.navigationBars["2 / 2"].exists)
        app.swipeRight()
        XCTAssertTrue(app.navigationBars["1 / 2"].waitForExistence(timeout: 5))
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.navigationBars["1 / 2"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["moment.101.image.1"].waitForExistence(timeout: 5))
        app.buttons["moment.101.image.1"].tap()
        XCTAssertTrue(app.navigationBars["2 / 2"].waitForExistence(timeout: 5))
        app.swipeDown(velocity: .slow)
        XCTAssertTrue(app.navigationBars["2 / 2"].waitForNonExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testGalleryContinuousGestures() {
        continueAfterFailure = false
        let app = launch("feed", emptyMoment: true)
        XCTAssertTrue(app.buttons["moment.101.image.1"].waitForExistence(timeout: 15))
        capture(app, name: "typography-feed")
        app.buttons["moment.101.image.1"].tap()
        XCTAssertTrue(app.navigationBars["2 / 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["gallery.photo.1"].waitForExistence(timeout: 5))
        capture(app, name: "gallery-second")
        for _ in 0..<4 {
            app.swipeRight(velocity: .fast)
            XCTAssertTrue(app.navigationBars["1 / 2"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.images["gallery.photo.0"].value as? String, "已加载")
            app.swipeLeft(velocity: .fast)
            XCTAssertTrue(app.navigationBars["2 / 2"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.images["gallery.photo.1"].value as? String, "已加载")
        }
        app.swipeLeft() // At the end, bounce without changing the selected image.
        XCTAssertTrue(app.navigationBars["2 / 2"].exists)
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let shortDrag = app.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: 0.5))
        middle.press(forDuration: 0.1, thenDragTo: shortDrag, withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertTrue(app.navigationBars["2 / 2"].exists)
        app.swipeRight(velocity: .slow)
        XCTAssertTrue(app.navigationBars["1 / 2"].waitForExistence(timeout: 3))
        app.buttons["重新加载图片"].tap()
        capture(app, name: "gallery-first")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["写絮语"].waitForExistence(timeout: 5))
        app.buttons["moment.101.image.1"].tap()
        XCTAssertTrue(app.navigationBars["2 / 2"].waitForExistence(timeout: 3))
        app.buttons["完成"].tap()
    }

    @MainActor
    func testSearchFocusGalleryAndArticleMenu() {
        let app = launch("feed", emptyMoment: true)
        XCTAssertTrue(app.buttons["搜索絮语"].waitForExistence(timeout: 15))
        app.buttons["搜索絮语"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["写絮语"].waitForNonExistence(timeout: 5))
        capture(app, name: "refined-search-keyboard")
        app.textFields["搜索已加载的絮语"].typeText("花")
        capture(app, name: "refined-search-moments")
        app.buttons["搜索絮语"].tap()
        XCTAssertTrue(app.buttons["写絮语"].waitForExistence(timeout: 5))
        app.buttons["moment.101.image.1"].tap()
        XCTAssertTrue(app.navigationBars["2 / 2"].waitForExistence(timeout: 5))
        app.swipeRight()
        XCTAssertTrue(app.navigationBars["1 / 2"].waitForExistence(timeout: 5))
        app.buttons["重新加载图片"].tap()
        capture(app, name: "refined-gallery")
        app.swipeLeft()
        XCTAssertTrue(app.navigationBars["2 / 2"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["写絮语"].waitForExistence(timeout: 5))
        app.tabBars.buttons["随笔"].tap()
        XCTAssertTrue(app.buttons["更多随笔操作"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["筛选文章：全部"].exists)
        app.buttons["更多随笔操作"].tap()
        capture(app, name: "refined-article-menu")
        app.buttons["已发布"].tap()
        app.buttons["搜索随笔"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["写随笔"].waitForNonExistence(timeout: 5))
        app.textFields["搜索站点随笔"].typeText("日常")
        capture(app, name: "refined-search-articles")
        app.buttons["搜索随笔"].tap()
        XCTAssertTrue(app.buttons["写随笔"].waitForExistence(timeout: 5))
        app.buttons["更多随笔操作"].tap()
        app.buttons["查看本机草稿"].tap()
        XCTAssertTrue(app.staticTexts["草稿箱"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["关闭草稿箱"].tap()
        XCTAssertTrue(app.buttons["写随笔"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRefinedReaderAboutMusicAndBrand() {
        let reader = launch("reader")
        XCTAssertTrue(reader.staticTexts["reader.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(reader.staticTexts["reader.metadata"].label.contains("#日常"))
        capture(reader, name: "refined-reader")
        reader.terminate()
        let about = launch("about")
        XCTAssertTrue(about.textViews["关于页面正文"].waitForExistence(timeout: 15))
        XCTAssertTrue(about.buttons["about.tool.图片"].exists)
        capture(about, name: "refined-about")
        about.buttons["about.tool.加粗"].tap()
        XCTAssertTrue((about.textViews["关于页面正文"].value as? String ?? "").contains("**"))
        about.buttons["about.tool.预览"].tap()
        XCTAssertTrue(about.navigationBars["Markdown 预览"].waitForExistence(timeout: 5))
        about.buttons["关闭"].tap()
        capture(about, name: "refined-about-editing")
        about.buttons["保存页面"].tap()
        XCTAssertTrue(about.staticTexts["设置已保存"].waitForExistence(timeout: 5))
        about.terminate()
        let feed = launch("feed", emptyMoment: true)
        feed.buttons["播放音乐列表"].tap()
        XCTAssertTrue(feed.navigationBars["听音乐"].waitForExistence(timeout: 10))
        capture(feed, name: "refined-music")
        feed.buttons["网站歌单"].tap()
        feed.buttons["listening.playlist.123456"].tap()
        XCTAssertTrue(feed.staticTexts["共 217 首 · 已加载 50 首"].waitForExistence(timeout: 10))
        capture(feed, name: "refined-playlist")
        feed.terminate()
        let manage = launch("manage")
        XCTAssertTrue(manage.buttons["management.文件管理"].waitForExistence(timeout: 10))
        capture(manage, name: "refined-management")
        manage.swipeUp()
        XCTAssertFalse(manage.buttons["management.站点概览"].exists)
        manage.terminate()
        let login = launch("login")
        XCTAssertTrue(login.images["抱叶子的小猫"].waitForExistence(timeout: 10))
        capture(login, name: "refined-login")
    }

    @MainActor
    func testRefinedDarkLargeTypeScreens() {
        continueAfterFailure = false
        for screen in ["reader", "about", "login"] {
            let app = XCUIApplication()
            app.launchArguments = ["--creation-preview", "--preview-screen", screen, "--ui-testing", "--preview-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
            app.launch()
            if screen == "reader" {
                XCTAssertTrue(app.staticTexts["reader.metadata"].waitForExistence(timeout: 15))
            } else if screen == "about" {
                XCTAssertTrue(app.buttons["about.tool.图片"].waitForExistence(timeout: 15))
                XCTAssertTrue(app.buttons["about.tool.预览"].isHittable)
            } else { XCTAssertTrue(app.images["抱叶子的小猫"].waitForExistence(timeout: 15)) }
            capture(app, name: "refined-dark-" + screen)
            app.terminate()
        }
    }

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
        XCTAssertLessThan(abs(app.buttons["写絮语"].frame.midY - app.buttons["player.mini"].frame.midY), 10)
        XCTAssertLessThan(app.buttons["player.mini"].frame.maxX, app.buttons["写絮语"].frame.minX)
        capture(app, name: "player-mini-moments")
        app.tabBars.buttons["随笔"].tap()
        XCTAssertTrue(app.buttons["player.mini"].waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(app.buttons["写随笔"].frame.midY - app.buttons["player.mini"].frame.midY), 10)
        XCTAssertLessThan(app.buttons["player.mini"].frame.maxX, app.buttons["写随笔"].frame.minX)
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
    func testMomentCommentsPaddingTapKeepsFeedPositionStable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--creation-preview", "--preview-screen", "feed", "--ui-testing", "--preview-lyric-cards", "--preview-empty-moment"]
        app.launch()
        let comments = app.buttons["moment-comments-101"]
        XCTAssertTrue(comments.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(comments.frame.width, 88)
        XCTAssertGreaterThanOrEqual(comments.frame.height, 44)
        let initialY = comments.frame.minY
        // Hit the transparent padding to the left of the unchanged text.
        func tapPadding() {
            comments.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 5, dy: 22)).tap()
        }
        tapPadding()
        XCTAssertTrue(app.buttons["回复"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(comments.value as? String, "已展开")
        XCTAssertEqual(comments.frame.minY, initialY, accuracy: 2)
        capture(app, name: "moment-comments-stable-expanded")
        for _ in 0..<3 {
            tapPadding()
            XCTAssertEqual(comments.value as? String, "已收起")
            XCTAssertEqual(comments.frame.minY, initialY, accuracy: 2)
            tapPadding()
            XCTAssertEqual(comments.value as? String, "已展开")
            XCTAssertEqual(comments.frame.minY, initialY, accuracy: 2)
        }
        app.terminate()
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
        app.tabBars.buttons["随笔"].tap()
        XCTAssertTrue(app.buttons["写随笔"].waitForExistence(timeout: 5))
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
        app.tabBars.buttons["随笔"].tap()
        XCTAssertTrue(app.buttons["更多随笔操作"].waitForExistence(timeout: 5))
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
        app.tabBars.buttons["随笔"].tap()
        XCTAssertTrue(app.buttons["写随笔"].waitForExistence(timeout: 5))
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
        app.tabBars.buttons["随笔"].tap()
        XCTAssertTrue(app.buttons["写随笔"].waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(app.buttons["写随笔"].frame.maxY, app.tabBars.buttons["随笔"].frame.minY, "写文章按钮不能被底栏遮住")
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

        app.tabBars.buttons["随笔"].tap()
        XCTAssertTrue(app.buttons["写随笔"].waitForExistence(timeout: 5))
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
        for (title, destination) in [("草稿箱", "草稿箱"), ("分类与标签", "分类与标签"), ("引用资料", "引用管理"), ("作品", "作品"), ("关于页面", "关于页面")] {
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
