# 叶子 · 原生阅读与创作 App

面向 Yezi 网站的 iOS 17+ 客户端。主导航为 **絮语 / 文章 / 评论 / 管理**，登录默认进入絮语；文件管理位于管理页的独立入口。正文、图片与 QQ 音乐可组合发布，纯图片不需要填入占位文案。登录页保留默认、备用及自定义站点。

## 创作与管理

- **絮语**：文字/照片/视频/音乐快捷记录、继续上次草稿、更多菜单筛选、Markdown 信息流、图片大图和折叠音乐。日期、位置、标签与评论数集中在底栏，按需展开评论并回复，与独立评论页共享状态。列表左滑编辑/删除；右下角写作入口在滚动期间收起，停止后恢复。
- **文章**：站点搜索、全部/服务器草稿/已发布筛选；分类、单行标题、摘要与日期/状态/标签组成列表，点击阅读，左滑编辑/删除。Markdown 格式栏支持在光标或选区插入标题、粗体、列表、链接与代码，可撤销/重做和切换预览。封面、Slug、分类、标签、关联附件和引用在发布设置中。保存服务器草稿是显式操作，首次 POST 后保存返回 ID，后续 PATCH；本机自动保存绝不将已发布文章转为草稿。
- **AI 配图**：编辑器「图片／照片 → AI 生图」，服务设置填写 CPA 的 HTTPS 地址、模型名称和 API 密钥。采用 OpenAI `POST /v1/images/generations`、Bearer 鉴权，兼容 `data[].b64_json` 和 `data[].url`；地址可填写根地址、`/v1` 或完整接口路径。配置只写入此设备钥匙串。描述画面后可生成、取消、重新生成；点击插入才上传到当前站点，在正文光标处插入 Markdown，可同时设为文章封面。未配置服务时不发送请求，失败不会自动重试生成。
- **听音乐**：絮语页顶部音乐入口打开播放列表，支持网站歌单分页、整行点歌、播放进度、顺序/随机/单曲循环、跨页面迷你播放条和系统锁屏控制。编辑器试听使用独立状态，退出后恢复正式队列。
- **网站备份**：管理页查看服务器数据库/完整加密备份，创建任务、下载分享及确认恢复。依赖网站 `/api/admin/v1/native-backups` 接口，与网站现有备份 API 分开；网站配套代码须部署后使用。恢复会清除旧登录会话。
- **评论**：底部菜单直接进入审核与回复；状态筛选、访客与来源信息、完整正文、已有回复和常用操作集中在独立卡片中。保存失败保留回复，允许重试；阻止保存期间的重复请求。
- **文件**：已加载文件搜索、类型筛选与排序，支持文件/相册上传、详情与引用、分享和删除。Markdown 原生阅读，PDF、图片及其他系统支持格式通过 Quick Look 预览，可分享或保存原文件。文件先通过现有会话下载到本机临时目录；无法预览时明确提示。
- **本机草稿**：从絮语/文章右上角和管理页进入，按站点保存文字、音乐与本地图片。只打开或聚焦内容不会创建草稿；首次修改后自动保存，切后台和关闭编辑器会保存未提交的改动。写盘失败留在编辑器并允许重试。
- **管理**：文件管理独立入口，基础信息、音乐、外观、GitHub 更新四个常用设置；作品、引用库、分类标签、关于页面统一卡片、表单、原生返回与保存区。引用阅读与更多操作分开呈现；分类、引用及回复编辑失败时保留输入。关于页面共用文章的 Markdown 格式栏、撤销重做和光标插入；音乐选择共用新版搜索器。站点概览的文章和絮语入口接入新版阅读与创作流程。

图片一次最多选择 9 张，按选择顺序显示占位与缩略图；后台 ImageIO 下采样到最长边 2048，JPEG 约 0.82，透明图片保留 PNG。上传并发最多 2，失败项可独立重试、移除和前后移动。未完成或失败图片会阻止发布；没有虚假的百分比进度。相机仅在点击“拍照”时请求权限，无相机设备显示解释。

音乐选择支持 QQ 歌曲/歌单搜索、站点隔离的最近添加、完整 QQ 链接及 `!music qqvip:MID:song` 手动输入（也兼容不带 `!music` 的输入）。想法发布使用 `!music qqvip:…` 行标记，并可用 `:fold` 把音乐折叠到想法顶部。播放器通过精确 MID 补充缺失的歌名、歌手与封面；所有卡片共享单一播放器，关闭/切后台停止。资源不可试听时仍能添加合法音乐。编辑旧内容兼容音乐代码块，保留多条音乐、未识别 Markdown 和引用。

发布只允许单次在途请求。响应不确定时保留草稿并引导核对列表，**不自动重发创建请求**，也不会误报“已发布”。只有已确认成功才清理本草稿；从本机删除图片或草稿不删除服务器附件。

## 打开与运行

使用 `/Applications/Xcode.app` 中的 Xcode 27 打开 `YeziApp.xcodeproj`，选择 `YeziApp` scheme。真机运行需要自己的签名 Team。通过 `/api/admin/login` 登录；密码不会落盘，管理员 Cookie 仅由系统会话管理，原生写请求保留 Origin 与 CSRF 头。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project YeziApp.xcodeproj -scheme YeziApp \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath /private/tmp/YeziCreationDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

## 离线原生视觉验收

**仅 Debug** 支持以下启动参数，Release 会编译移除 fixture 实现。Debug 明确使用 `DEBUG` 与 `-Onone`。

```bash
xcrun simctl install <device-id> /private/tmp/YeziCreationDerivedData/Build/Products/Debug-iphonesimulator/YeziApp.app
xcrun simctl launch <device-id> me.aluvien.yeziblog --creation-preview --preview-screen composer
```

`--preview-screen` 可取 `feed`、`composer`、`music`、`articles`（文章列表）、`article`（文章编辑器）、`reader`（文章阅读）、`comments`、`reply`、`files`、`file-reader`（Markdown 文件）、`file-pdf`、`file-image`、`drafts`、`settings`（发布设置）、`manage`、`site-settings`、`music-settings`、`appearance`、`updates`、`works`、`work-editor`、`taxonomy`、`taxonomy-editor`、`references`、`reference-editor`、`reference-cache`、`reference-reader`、`about`、`overview`。加 `--preview-keyboard` 可让 composer/article 正文聚焦显示真实键盘；普通 preview 不自动弹出键盘。演示使用独立 `creation-preview.invalid` 站点、受控 URLProtocol 响应及本地图片，不访问线上 API/音频/图片。演示草稿仍保存在模拟器本机，可检查离开与恢复。正常启动不受 preview 影响。

## 模块与数据安全

- `YeziApp/Creation/CreationDraftStore.swift`：canonical origin 隔离、原子 JSON、revision 防旧写覆盖、文件保护、损坏文件保留且不隐藏健康草稿、只清理严格 UUID 归属的 jpg/png。
- `MediaUploadQueue.swift`：后台处理、并发槽、取消晚到保护、重试与本地文件生命周期。
- `CreationComposerModel.swift`：可靠本机保存、文章严格加载、一次性提交快照、状态与终态保护。
- `CreationComposerView.swift`、`CreationHubViews.swift`、`MusicPicker.swift`：独立可见编辑顶栏、四 tab 原生页面、音乐搜索/试听。
- `CreationAudioPlayer.swift`、`CreationListeningView.swift`：共享播放队列、试听恢复、迷你播放条与系统媒体控制。
- `MarkdownWritingView.swift`：UITextView 光标/选区格式操作、中文输入、撤销与重做。
- `AIImageService.swift`、`AIImageComposerView.swift`：OpenAI 兼容生图、钥匙串配置、取消与图片预览。图片 URL 下载不附带 CPA 鉴权；生成接口的重定向不会转发密钥。
- `AttachmentReaderView.swift`：文件分类、临时下载、Markdown 阅读与 Quick Look 预览。
- `Views/RootContentView.swift`：登录/站点/会话路由与原管理功能；旧创作入口统一接入新编辑器。
- `Networking/APIClient.swift`：真实私有 API、严格文章必需字段、直接/包裹响应识别和真实 decoder 的分页别名。

本机草稿位于 Application Support/CreationDrafts，按站点 origin 摘要分目录，不保存密码或 Cookie，不会静默删除损坏 JSON。删除草稿需确认；音乐最近记录与其它草稿不受影响。

## 回归验证

`YeziInteraction` scheme 提供独立的原生界面回归：从首页选择音乐后继续输入、收起键盘后点击正文留白再次输入、点击管理列表文字与箭头间的空白、点击设置卡片边距。测试使用离线演示账户和独立临时草稿目录，不访问生产 API，也不复用真实草稿。运行方式：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project YeziApp.xcodeproj -scheme YeziInteraction \
  -destination 'platform=iOS Simulator,id=<device-id>' \
  -derivedDataPath /private/tmp/YeziInteractionFixDerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

`YeziAppTests/CreationTests.swift` 全部网络交互使用 URLProtocol fixtures，覆盖草稿重建/缺失/损坏、站点隔离、终态和清空保存、四种想法 payload、双击/超时、图片并发/在途移除/定向重试、音乐查询 generation、封面与引用、严格响应/分页、文章 POST→PATCH 及远端已发布状态保护。原有测试保持运行。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project YeziApp.xcodeproj -scheme YeziApp \
  -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=499FCB18-FC0B-4C89-A0F7-28345BEBE2CB' \
  -derivedDataPath /private/tmp/YeziCreationDerivedData \
  -resultBundlePath /private/tmp/YeziCreationTests-unique.xcresult \
  CODE_SIGNING_ALLOWED=NO test

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project YeziApp.xcodeproj -scheme YeziApp \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/YeziCreationDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

相机拍摄、系统照片实际选择、真实 QQ 音频和线上创建需要人工实机验收；自动回归不会写入线上服务。2026-10-15 改版截图见 `docs/design/interaction-20261015/index.html`；历史 A01–A20 设计验收保存在 `docs/design/`。
