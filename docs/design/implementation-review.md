# 想法优先改版 · 监督验收

## 2026-10-23 TestFlight 1.0（29）与 GitHub 同步

- 最终 Release 签名归档：`/private/tmp/YeziApp-1.0-29-final.xcarchive`，日志 `/private/tmp/yezi-testflight-29-final-archive.log`。包内版本为 **1.0（29）**。Xcode Organizer 使用现有账号完成上传，明确显示 `App upload complete` 和 `YeziApp 1.0 (29) uploaded`；Apple 后续处理与测试员可安装状态尚未核验。
- 包含本轮共享播放器、紧凑歌单、试听恢复、迷你播放条及此前尚未同步的原生界面、媒体编辑、AI 配图、行内评论、备份与小猫图标。以下各节「未发布」描述保留为当时记录。
- 上传前完整单元测试 **115 项通过**（`/private/tmp/yezi-build29-unit.xcresult`）；备份及行内评论的浅色/深色大字 **2 项 UI 回归通过**（`/private/tmp/yezi-build29-backup-ui.xcresult`）。播放器的常规屏、小屏与深色验证详见下节。
- 网站基于远端最新 `82cca17` 独立整合，没有用旧本地树覆盖远端。App 备份协议改用 `/api/admin/v1/native-backups`，保留网站现有备份接口与云备份流程；共享任务锁、文件锁及部署锁，归档排除恢复任务目录。网站完整测试 **380 项通过、1 项跳过**，TypeScript、定向 ESLint 及生产构建通过（`/private/tmp/yezi-web-release29-{tests-final,types-final,lint,build}.log`）。
- 网站新增接口仍需部署后生效。本轮没有在真实网站执行备份或恢复，没有部署生产网站。网站原工作目录中的既有修改保留。

## 2026-10-23 音乐播放器交互重做（本地，未发布）

- 听音乐改为当前歌曲、进度/控制与紧凑列表；歌曲整行响应，当前曲目高亮，支持顺序、随机、单曲循环、上一首/下一首和暂停续播。网站歌单保留原始总数并分页读取资料，不再以成功解析播放地址的歌曲数替代歌单数量。
- App 增加 `CreationAudioPlayer.swift` 与 `CreationListeningView.swift`：共享正式队列、独立编辑器试听、原生迷你播放条、后台音频声明、锁屏信息/封面和远程控制；试听返回恢复原队列与位置。音频会话激活放在独立 actor，避免阻塞主线程；每个实际播放器只有一个每秒进度观察器，切歌取消过期请求。
- 网站 `api/music/qq?type=playlist-metadata` 接受 `offset` 和 `limit`（1–100），返回 `total`、`availableTotal`、`nextOffset`。不带分页参数保留原网站前 20 首行为，不批量解析音频地址。旧网站未更新时，App 如实提示仅返回部分资料；网站源代码需部署后才能加载完整歌单。
- 视觉验收中发现迷你播放条会盖住悬浮写作按钮，已按播放条的实际高度抬高两个入口，并加入位置断言与实际打开编辑器的回归。絮语音乐卡片也改为封面、歌名、歌手整块响应；独立试听按歌曲 ID 判断播放状态，避免资料补全后按钮状态丢失。分页去重同时覆盖页内和跨页重复。
- 最终完整单元测试 **115 项通过**：`/private/tmp/yezi-player-unit-final.xcresult`；Release 无签名构建通过：`/private/tmp/yezi-player-release-final.log`。网站分页、公开访问授权、歌词回归 **11 项通过**（`/private/tmp/yezi-music-web-tests3.log`），后续分页/权限 8 项复核通过；TypeScript 与定向 ESLint 通过。
- iPhone Air 四项 UI 回归通过：`/private/tmp/yezi-player-ui-final.xcresult`，覆盖整行点歌、暂停/续播、切歌、队列、跨页迷你播放条、编辑器试听恢复、深色大字和失败提示。375pt 小屏完整流程通过：`/private/tmp/yezi-player-ui-small-verified.xcresult`，额外验证进度拖动、回到曲首、队列折叠和写作入口避让；小屏深色大字测试在 `/private/tmp/yezi-player-ui-small-final.xcresult` 单项通过。该结果包中的另一项最初因测试将手势落点要求为精确 30 秒而失败，实际到达 33 秒，修正合理精度范围后完整复测通过。
- 已人工检查实际模拟器截图，保存在 `docs/design/music-player-20261023/`。截图使用离线测试数据和统一占位封面；UI 播放测试使用真实本地静音 WAV 验证 AVPlayer 状态，不能代替真实 QQ 音频、真机耳机和锁屏验收。没有测量真机温度或能耗，不能据此承诺降温效果。
- 本轮没有推送 GitHub、部署网站或上传新的 TestFlight，已上传的 1.0（28）不含本轮播放器修改。

## 2026-10-23 TestFlight 1.0（28）上传

- Release 签名归档成功：`/private/tmp/YeziApp-1.0-28.xcarchive`，日志 `/private/tmp/yezi-testflight-28-archive.log`。
- 命令行上传返回账号访问错误；改用 Xcode Organizer 现有账号成功上传，界面明确显示 `App upload complete` 和 `YeziApp 1.0 (28) uploaded`。未要求重新登录。Apple 后续处理与测试分发状态尚未核验。
- 包含燕麦白＋鼠尾草绿配色及当前 App 修改；行内评论、网站备份功能需要部署对应网站接口。GitHub 推送尚未完成。

## 2026-10-23 正式采用方案一：燕麦白＋鼠尾草绿

- 用户从四套实际模拟器配色预览中选择方案一。正式浅色背景 `#F2EFE8`、卡片 `#FAF8F3`、强调色 `#557460`；柔和表面 `#E7E5DB`、浅强调背景 `#E1E7DC`、分割线 `#D7D4C9` 与所选预览一致。
- 深色背景改为暖炭灰 `#201F1C`，卡片 `#2B2A26`，强调色 `#ADC3A6`。保留系统文字、玻璃材质与原生交互，管理页共享同一套色彩；同步 AccentColor 资源。
- 四套方案比较仍仅在 Debug 离线预览启用。普通启动与 Release 默认采用方案一。
- 浅色媒体菜单与页面 UI 测试、深色页面与滚动恢复 UI 测试各 1 项通过，结果为 `/private/tmp/yezi-oat-final.xcresult` 与 `/private/tmp/yezi-oat-dark.xcresult`。已检查管理页浅深色截图；实际模拟器截图保存在 `docs/design/oat-sage-20261023/`，使用离线测试数据。本轮未上传 TestFlight。

## 2026-10-23 絮语位置、行内评论与网站备份

- 原生筛选菜单补齐全部、照片、音乐、文字图标。底栏显示日期、网站已有位置和标签；右侧仅在有评论时显示评论数，包含待审核记录，管理员回复不另计数。
- 评论按絮语展开后加载、20 条分页，支持直接回复/修改回复与失败重试。每个 API 会话拥有独立共享评论存储，与评论页同步回复、审核和删除；站点切换、退出与登录失效不复用旧站数据。延迟返回的旧查询不会覆盖新回复。
- 管理新增「网站备份」：数据库/完整加密备份、服务器记录、后台任务状态、流式下载后通过系统分享保存到文件、原生恢复确认。轮询只在页面可见且任务运行时进行；下载退出时取消并清理临时文件。
- 网站增加目标评论筛选与批量计数，避免每条絮语请求一次计数。备份接口复用既有数据库快照和加密归档；恢复由独立任务在 PM2 停机后进行，先校验、保存当前快照，再切换、带写保护启动、健康检查，失败回退。恢复清除旧会话，需重新登录。没有在真实网站执行恢复。
- 网站相关测试 25 项通过，包含临时数据库、伪 PM2 独立任务、损坏加密文件拒绝、下载字节一致性、恢复回退与评论目标隔离；TypeScript 类型和定向 ESLint 通过。日志：`/private/tmp/yezi-backup-tests-final3.log`、`/private/tmp/yezi-backup-types-final2.log`、`/private/tmp/yezi-backup-lint-final.log`。
- App 最终 109 项单元测试通过（含跨页面更新/删除、站点隔离、旧响应不能覆盖新回复）；Release 无签名构建通过。常规屏、375pt 窄屏全流程和深色辅助功能大字体 UI 测试均通过，已人工检查截图。结果：`/private/tmp/yezi-comments-backups-unit-final.xcresult`、`/private/tmp/yezi-comments-backups-ui-final.xcresult`、`/private/tmp/yezi-comments-backups-small2.xcresult`、`/private/tmp/yezi-comments-backups-accessibility.xcresult`；构建日志 `/private/tmp/yezi-comments-backups-release.log`。窄屏测试需先将评论入口滚离浮动写作按钮区域。实际运行截图位于 `docs/design/comments-backups-20261023/`，为离线测试数据，不是线上备份记录。
- 尚未提交、推送、部署或上传 TestFlight。上线需要先部署网站接口及 `scripts/backup-*`，完整加密备份需原有 `DATA_BACKUP_KEY`；恢复要求 PM2 托管与标准持久化目录，详见网站备份 API 文档。

## 2026-10-23 雾绿灰配色与布局复核

- 按用户选定方向统一浅色雾绿灰背景 `#E6ECE7`、卡片 `#F0F3EE`、叶绿强调色 `#426653`；深色分别为 `#18201C`、`#222D26`、`#A6C4AE`。更新 AccentColor 资源的浅深色值，保留系统玻璃及弹窗材质。强调色在两种背景上的计算对比度为浅色 5.38–5.76:1、深色 7.56–8.82:1。
- 絮语筛选移入右上角更多菜单；选择照片等筛选时副标题显示当前条件，删除独立筛选行。日期改为 `yyyy-MM-dd HH:mm`，与标签同排，标签允许在有限宽度中换行。
- 管理页顶部网站信息与统计合为一个列表单元，内部横线左右等距；跳转图标替换为系统 chevron，仍为整行打开 App 内浏览器。
- 辅助功能大字体下页头操作移到标题下方，避免横向挤压。
- Air 的 2 项 UI 测试通过：`/private/tmp/yezi-mist-ui.xcresult`；375pt 的 3 项 UI 测试通过：`/private/tmp/yezi-mist-small.xcresult`，覆盖浅深色、筛选切换、媒体菜单、大字体与滚动恢复。已检查实际截图，存放于 `docs/design/mist-green-20261023/`；使用离线测试数据。
- 本轮仅修改 App，未重新执行不相关的服务端测试或上传发布。

## 2026-10-23 小猫图标与系统交互改版（本地实现，未发布）

- 使用用户提供的小猫抱叶子照片，等比例转换为 1024×1024、无透明通道的 PNG AppIcon；未重绘、未预制圆角。
- 页面采用系统动态背景、系统标题字体和玻璃按钮。文章列表改为分类胶囊＋单行标题、三行摘要、日期／状态／标签，移除封面缩略图。旧接口没有摘要时不补发详情请求。
- 絮语显示网站作者信息、标题旁折叠音乐、图片网格以及底部日期与标签；纯标签段落不再在正文重复显示。保留系统左滑编辑、删除。
- 筛选改为系统菜单；顶部音乐入口打开「听音乐」，分絮语音乐、网站歌单，按需分页及加载歌曲，不自动播放。写作入口在拖动、减速期间收起，停止 300ms 后恢复，尊重减少动态效果设置。
- 图片菜单统一材质，依次为 AI 生图、拍照、插入图片。视频独立入口支持相册 MP4/MOV（20 MB）、上传进度／重试、视频链接；视频按光标插入，使用网站兼容的 `!video <url>` 格式。
- 管理页使用系统分组列表，统计三等分居中，网站信息在 App 内系统浏览器打开。
- 网站仓库 `/Users/aluvien/Develop/Website/yezi-blog` 同步增加管理文章摘要、视频类型／文件头校验、上传文件 Range/HEAD 响应和视频短代码渲染；保持现有认证、上传大小上限。**尚未部署网站**，线上摘要和视频上传能力依赖此次服务端更新。

验证记录：

- 最终单元测试 **107 项通过**：`/private/tmp/yezi-oct23-unit-final.xcresult`。
- 第一轮 4 项交互回归通过：AI 生图插入、音乐后输入、试听失败提示、新页面及媒体菜单，结果 `/private/tmp/yezi-oct23-ui.xcresult`。
- 375pt 窄屏浅深色及滚动恢复 2 项测试通过：`/private/tmp/yezi-oct23-ui-small.xcresult`。截图检查发现并修正了分类胶囊被标题挤压的问题。
- 最终 4 项 UI 验收通过：管理入口留白点击、整行点击、浅深色及滚动恢复、媒体菜单与视频链接插入，结果 `/private/tmp/yezi-oct23-ui-final.xcresult`。本轮累计 7 个不同 UI 测试场景通过；Air 与 375pt 截图保存于 `docs/design/native-refresh-20261023/`。
- iOS Release 无签名编译通过：`/private/tmp/yezi-oct23-release-final.log`。本轮没有归档上传 TestFlight，没有推送 GitHub，版本号仍为 1.0（27）。
- 网站 Markdown、上传及 API **39 项测试通过**，TypeScript 与改动源文件 ESLint 检查通过：`/private/tmp/yezi-oct23-web-final.log`、`/private/tmp/yezi-oct23-web-final-types.log`、`/private/tmp/yezi-oct23-web-lint.log`。
- 截图为 iOS 27 模拟器运行 App 的离线测试数据，不是在线站点数据或设计渲染图。真机相机、线上视频上传／歌曲播放仍需部署后联调，未将模拟器菜单测试视为这些能力的端到端验证。

## 2026-10-21 1.0（27）TestFlight 上传成功

- 构建号从 26 升到 27；完整单元测试 **105 项通过**，结果 `/private/tmp/yezi-build27-unit.xcresult`。底部玻璃按钮的 2 项 UI 回归通过，结果 `/private/tmp/yezi-transparent-compose-20261021.xcresult`。
- Release 签名归档成功：`/private/tmp/YeziApp-1.0-27.xcarchive`，日志 `/private/tmp/yezi-testflight-27-archive.log`。包内版本为 `1.0 (27)`、标识为 `me.aluvien.yeziblog`、团队为 `DR2TNGTRAJ`，`codesign --verify --deep --strict` 通过。
- **00:44 与 00:51（Asia/Shanghai）两次命令行上传失败**：`xcodebuild -exportArchive` 报 `exportArchive Failed to Use Accounts`，其中第二次日志显示钥匙串账户记录缺少 `Xcode-Username`；日志分别为 `/private/tmp/yezi-testflight-27-upload.log`、`/private/tmp/yezi-testflight-27-upload-after-login.log`。这不是归档或代码签名失败。
- 改用 Xcode Organizer 打开**同一份** 1.0（27）归档并选择 App Store Connect 分发，界面给出 `App upload complete: YeziApp 1.0 (27) uploaded`。**01:04（Asia/Shanghai）** Organizer 列表显示 `Uploaded to Apple`，提交状态中的构建号为 **27**。分发日志在 `/var/folders/zm/d8g9437n3c3g9mjxkmgtt6dr0000gn/T/YeziApp_2026-10-21_00-54-22.789.xcdistributionlogs/`。Apple 后续处理完成及测试员可安装状态尚未确认；10 月 20 日各节的「尚未上传」表述记录的是当时状态。

## 2026-10-21 写絮语／写文章底部背景修正（已纳入 1.0（27））

- 两个列表原先用 `safeAreaInset` 放新增按钮，并给整行铺页面底色，因此系统玻璃按钮之外也出现不透明横带。改为列表上方的原生玻璃按钮悬浮层，不再绘制整行背景；列表末尾保留 80pt 可滚动留白，最后一条内容可以滚到按钮上方。
- iOS 27 深色 UI 测试 `testReportedDarkScreensAndUnobstructedComposeButton` 和 `testEditorialScreensAndNavigation` 均通过，结果 `/private/tmp/yezi-transparent-compose-20261021.xcresult`。人工核对模拟器截图：`docs/design/transparent-compose-20261021/`，包括絮语、文章及列表末尾。
- 本次改动已随 1.0（27）上传 TestFlight；视觉验收依据仍是本地 iOS 27 模拟器截图，尚未获得新版本的真机反馈。源码尚未同步 GitHub。

## 2026-10-20 系统列表与评论头像（尚未上传）

- 絮语、文章主列表改为系统 `List`，左滑出现原生「编辑」「删除」动作，删除仍先弹确认。絮语卡片移除常驻编辑与更多图标，复制文字留在系统长按菜单；文章卡片移除常驻编辑入口。
- 两页右下角改为 44pt 高的系统玻璃胶囊按钮，分别显示「＋ 写絮语」「＋ 写文章」。絮语、文章、评论筛选改用原生分段 `Picker`；评论常用操作使用系统 bordered 按钮。
- 文章分类、日期、状态合并同一行，标题收至 18pt 且只显示一行，超出用省略号；封面缩为 72pt 方形。实际 `yezi.me` 数据的 iOS 27 模拟器页面已目视核对。
- 网站的访客头像可能是 `data:image/svg+xml`。App 现在优先使用评论接口中的 `avatar` / `avatar_url`，对网站的小型 SVG 在本机绘制；普通 URL 照常加载。真实管理接口当前返回的评论未提供头像时，使用稳定的网站同类彩色图形作为占位，无法还原原评论的精确随机配色；有邮箱时尝试 Gravatar。
- 原有浅/深色界面测试通过：`/private/tmp/yezi-system-list-review.xcresult`；新增两页左滑 UI 测试在 iPhone Air 与 375pt 小屏均通过：`/private/tmp/yezi-native-swipe-20261020.xcresult`、`/private/tmp/yezi-native-list-small-ui.xcresult`；头像字段解码与来源摘要 3 项单元测试通过：`/private/tmp/yezi-comment-avatar-20261020.xcresult`。SVG 与缺图占位头像界面回归通过：`/private/tmp/yezi-site-avatar-svg-ui.xcresult`、`/private/tmp/yezi-site-avatar-fallback-ui.xcresult`。实际站点数据的三页截图及离线左滑演示截图在 `docs/design/native-list-20261020/`。
- 当前仅在本地 Debug 模拟器验证，未重新归档、上传 TestFlight 或同步 GitHub。

## 2026-10-20 iOS 27 原生导航修正（尚未上传）

- 之前虽使用 `TabView`，但把系统标签栏隐藏并自行绘制底部导航，因此 iOS 27 的浮动材质、选择反馈和层次没有出现。现在直接显示 SwiftUI 原生 `TabView` 标签栏，四个主页面仍保留纸白、衬线字和朱红内容风格。子页面沿用现有收起标签栏逻辑。
- 右下角新增按钮在 iOS 26 及更新系统使用圆形 `.glass`：最初的 `.glassProminent` 配合朱红色 tint 会把圆面填实，已按反馈改为半透明系统玻璃，朱红仅保留在加号上；iOS 17–25 保留可用的原按钮。
- 页首的搜索、音乐和草稿入口也使用系统玻璃按钮，保留编辑感的标题与内容；控制尺寸已收紧，避免抢占标题空间。
- iPhone Air 浅色与深色两项导航 UI 回归通过：`/private/tmp/yezi-ios27-native-tabs.xcresult`；375pt 小屏浅色导航通过：`/private/tmp/yezi-ios27-small-tabs.xcresult`；最终页首按钮尺寸与四页导航通过：`/private/tmp/yezi-ios27-compact-header.xcresult`。原生玻璃标签栏及新增按钮已目视核对；实际站点数据截图 `docs/design/ios27-native-20261020/feed-live.png`。
- 透明加号修正后，iPhone Air 浅色四页导航回归 `/private/tmp/yezi-ios27-clear-fab.xcresult` 与深色底部按钮回归 `/private/tmp/yezi-ios27-clear-fab-dark.xcresult` 各通过 1 项；实际 `yezi.me` 数据的浅色运行截图为 `docs/design/ios27-native-20261020/feed-live-clear-glass.png`，已目视核对圆面不再是朱红实心。
- 本次未重新归档或上传 TestFlight，线上 1.0（26）仍显示原底栏。

## 2026-10-20 TestFlight 截图反馈修正（尚未上传）

- 用户四张深色实机截图显示：评论来源暴露音乐 Markdown 标记，絮语新增按钮覆盖播放器，文章日期与状态分行导致列表偏松。深色配色本身来自系统外观切换，保留跟随系统行为；管理页未发现仅凭截图能够确认的功能错误。
- 评论来源增加本地摘要转换，正文优先；只有音乐时显示已包含的歌名/歌手或「音乐絮语」，不额外发请求。回复正文使用正文颜色，朱红保留在操作提示上。
- 絮语与文章新增按钮改用底部安全区域，占用独立空间；列表内容不再与按钮重叠。文章标题由 23pt 收到 21pt，日期、状态与编辑入口合并一行。
- 两项评论来源单元测试通过：`/private/tmp/yezi-screenshot-fixes-unit.xcresult`。浅色导航回归通过：`/private/tmp/yezi-screenshot-fixes-ui-verified.xcresult` 中 `testEditorialScreensAndNavigation`；同次深色测试因 XCTest 查询条件不支持而失败，修正测试查询后独立深色回归通过：`/private/tmp/yezi-screenshot-fixes-dark-final.xcresult`。此前一次测试查询编译错误也已修正，不将失败运行记为通过。
- 实际模拟器截图保存在 `docs/design/screenshot-review-20261020/`，人工复核评论摘要及列表末尾播放器/新增按钮的分离。使用离线数据，不代表真机线上验证。本次没有重新归档、上传 TestFlight 或推送 GitHub，线上仍为 1.0（26）。

## 2026-10-20 1.0（26）归档与上传成功

- 本次纸白、墨黑与朱红界面、七项 Markdown 工具栏、音乐搜索试听诊断和 CPA/OpenAI 兼容生图已纳入 **1.0（26）**。102 项单元测试、3 项界面测试和 Release 构建通过；补充服务设置截图后的生图完整 UI 回归也通过，结果 `/private/tmp/yezi-ai-image-screenshots-20261020.xcresult`。
- 签名归档完成，`codesign --verify --deep --strict` 通过；归档版本与 bundle ID 已核对为 `1.0`、`26`、`me.aluvien.yeziblog`。正式可执行文件不含离线模型、演示服务域名或临时生图日志标记。
- 归档 `/private/tmp/YeziApp-1.0-26.xcarchive`；归档日志 `/private/tmp/yezi-testflight-26-archive.log`。
- **2026-10-20 18:19（Asia/Shanghai）首次上传失败**：Apple 返回 `exportArchive Failed to Use Accounts`，要求恢复团队 `DR2TNGTRAJ` 的 App Store Connect 账户访问。该次未进入 Apple 处理，日志 `/private/tmp/yezi-testflight-26-upload.log`。
- 用户恢复账户登录后，使用同一归档继续上传。**2026-10-20 18:26（Asia/Shanghai）上传成功**，Apple 返回 `Upload succeeded`、`EXPORT SUCCEEDED`，接收状态为 `Uploaded package is processing`。成功日志 `/private/tmp/yezi-testflight-26-upload-after-login.log`；尚未确认后续处理完成或测试员可安装状态，未同步 GitHub。
- 真实 CPA 配置与出图联调、QQ 音频恢复及真机能耗采样仍保留此前的验证边界。

## 2026-10-20 CPA/OpenAI 兼容 AI 配图

- 图片菜单按参考图排列：上方「AI 生图」，下方「插入图片」。AI 配图支持画面描述、三种标准尺寸、生成/取消、预览、重新生成、插入正文及可选文章封面；原七项 Markdown 工具栏保留。
- 新增 `AIImageService.swift` 与 `AIImageComposerView.swift`。接口采用 `POST /v1/images/generations`，Bearer 鉴权；发送 `model`、`prompt`、`n: 1`、`size`，避免向 GPT Image 发送不支持的 `response_format` 参数，同时兼容 Base64 和 HTTPS 图片 URL 返回。地址支持根地址、`/v1` 和完整接口路径，不猜测 CPA 实际的模型别名。
- 地址、模型和密钥通过 App 内服务设置写入系统钥匙串；不写入源码、普通偏好或站点草稿。生图会话独立于管理员会话，图片 URL 下载不附带 CPA 鉴权。生成请求不自动重试，关闭/取消会取消网络任务；含鉴权的重定向不会转发，下载结果验证体积和图片尺寸，处理和压缩在后台完成。
- 只有点「插入正文」才通过当前管理员会话上传到站点。在保留的正文光标处插入 Markdown，关联附件，可同时设置封面；上传失败保留预览，可再次插入，不触发重新生成。取消、错误提示和插入操作保持在底部可见区域。
- 完整单元测试 **102 项通过**，含 10 项新回归：接口地址规范化、钥匙串持久化、请求鉴权/JSON/Base64、图片下载的密钥隔离、状态错误脱敏/不重试、无效返回、网络取消、附件/封面关联、离线上传响应契约及无键盘时的光标插入。结果 `/private/tmp/yezi-ai-image-unit-final.xcresult`，日志 `/private/tmp/yezi-ai-image-unit-final.log`。
- 首轮 UI 发现离线上传夹具缺少解析器要求的顶层 `path` 字段，导致插入失败；增加单独契约测试后修正夹具。375pt 完整生成→预览→插入→封面设置回归 **1 项通过**：`/private/tmp/yezi-ai-image-end-to-end.xcresult`。失败记录保留，未将其记为通过。一次失败测试在整理结果时停滞超过两分钟，已停止该进程，后续独立测试完成正常。
- Release 构建通过：`/private/tmp/yezi-ai-image-release-final.log`。真实 CPA 地址、模型和密钥尚未填写，离线生成/上传测试不代表真实 CPA 或站点写入联调成功。尚未上传 TestFlight 或同步 GitHub。
- 最终大屏 **3 项 UI 回归通过**：生图生成/预览/插入/封面、七项工具栏/撤销/预览返回，以及音乐后继续输入。结果 `/private/tmp/yezi-ai-image-ui-final.xcresult`，日志 `/private/tmp/yezi-ai-image-ui-final.log`。已人工复核实际截图并加入图册；Release 可执行文件不含演示服务域名、离线生图模型或临时阶段日志标记。

## 2026-10-20 文章编辑器按参考图纠偏

- 上一轮仍保留旧双层工具栏和顶部模式切换，与用户认可的图不符。本次改为底部单排「加粗、标题、链接、列表｜图片、音乐、预览」，图片、音乐与预览均直接可用；取消／发布改为轻量文字按钮。
- 撤销、重做、其他格式、发布设置、引用、附件和舍弃草稿收进标题旁的选项菜单。正文不再出现发布设置入口；预览使用独立 sheet，避免销毁正文输入控件及其选区和撤销栈。关于页面的完整格式栏保留。
- 375pt 小屏回归 **1 项通过**：七个入口同排、点击宽度至少 44pt、键盘下仍可点、加粗、撤销还原、插入链接、预览返回保留正文、列表后继续输入。结果 `/private/tmp/yezi-toolbar-small.xcresult`。
- iPhone Air **2 项通过**：同一编辑器回归，以及选音乐后继续输入、再次取消选歌后点击留白输入。结果 `/private/tmp/yezi-toolbar-modern.xcresult`。本轮未重新运行上轮的完整 92 项单元测试。
- Release 构建通过：`/private/tmp/yezi-toolbar-release.log`。人工对照实际小屏截图及键盘截图，图册更新 `small-editor.png`、`small-editor-keyboard.png` 和 `modern-editor.png`。正文仍使用 Markdown 源码编辑，未声称实现参考图中的所见即所得排版或 AI 生图服务。
- 本次未上传 TestFlight、未同步 GitHub。

## 2026-10-20 纸白、墨黑与朱红 · 原生界面落地

- [实际截图图册](editorial-20261020/index.html)包含 14 个大屏页面及小屏、深色大字体检查，图片均来自原生 App 的 DEBUG 离线样本；[实现与素材说明](editorial-20261020/README.md)记录设计边界、字体许可与演示照片来源。
- 统一纸白/暖黑背景、朱红操作色、离线 Noto Serif SC 中文标题、细分隔线、小圆角按钮；重排絮语、文章、评论、管理、文件、基础设置和编辑器。管理入口整行点击，文件图片筛选使用自适应网格。音乐、外观、更新、作品、分类、引用和关于页面同步共用样式。
- 四个主导航保留独立 NavigationStack；使用平面底栏，子页收起，返回恢复。首轮截图发现系统底栏与新底栏重叠、浮动按钮受遮挡、中文系统字体回退和分隔线方向异常，均修复并重新截图验证。
- 单元测试 **92 项通过**，包括新增加的字体离线注册与中文字符覆盖测试。日志 `/private/tmp/yezi-editorial-unit.log`，结果 `/private/tmp/yezi-editorial-unit.xcresult`。
- 7 个独立 UI 场景分别完成验证：音乐后继续输入、搜索试听失败仍可选择添加、管理行间空白点击、管理入口边缘点击、核心页面导航/截图、辅助页面导航/截图，以及大字体深色检查。首轮 6 场景中 5 通过，1 项在入口只有部分可见时误点到被底栏遮挡的坐标；测试增加整行进入可见区域的判断后，5 个入口边缘点击全部通过，结果 `/private/tmp/yezi-editorial-hitarea-verified.xcresult`。
- 大屏核心与 7 个管理子页面共 **2 项 UI 测试通过**：`/private/tmp/yezi-editorial-modern.xcresult`。375pt 核心导航和大字体共 **2 项通过**：`/private/tmp/yezi-editorial-small-verified.xcresult`。写文章按钮包含位置断言，确认完整位于底部导航上方。
- 人工截图复核发现系统启动参数没有实际切到深色，不能凭测试通过认定深色已验收；新增仅限 DEBUG 离线演示的 `--preview-dark` 后，独立重跑 **1 项通过**，人工确认暖黑背景、浅色字、低饱和朱红和大字体排版：`/private/tmp/yezi-editorial-dark-verified.xcresult`。图册已替换为实际深色截图。
- 首轮含失败的 Xcode 测试在所有用例结束后整理结果包时停滞，已中断该测试进程；该轮日志保留在 `/private/tmp/yezi-editorial-ui-final.log`。独立复测结果包均正常完成，不将该轮整体记为成功。
- Release 构建通过，无源码告警：`/private/tmp/yezi-editorial-release.log`。工程 plist、scheme XML、图册资源引用和 `git diff --check` 均通过。没有改动既有审核/草稿/音乐播放语义，保留此前未发布的音乐错误诊断修复。
- 尚未上传 TestFlight 或同步 GitHub。AI 生图服务仍待确定，未接入真实生成 API；本轮也没有新增真机温度/能耗测量。

## 2026-10-17 搜索添加音乐时无法试听（服务异常已核对）

- 在站点已有管理员会话下核对：音乐设置显示「已登录 · 播放异常」，状态接口返回 `available: true`、`loggedIn: true`、`playable: false`、`healthStatus: playback_unavailable`；诊断为账号有效，但探测歌曲未返回播放地址。健康检测时间为 2026-10-17 20:13（Asia/Shanghai）。
- 同一管理员会话下请求「晴天」MID `003OUlho2HcRHC` 的 `type=track` 接口，返回「QQ 音乐服务暂不可用，请稍后再试」。搜索元数据与播放地址解析属于不同请求；已确认本次新歌曲解析存在服务端故障，尚不能证明用户每次失败都只有同一原因。已有公开缓存音频的可播放结果不能替代新搜索歌曲验证。
- App 原先只解码 `available`、`loggedIn` 和账号信息，漏掉 `playable` 与服务诊断；试听错误又被统一替换成「暂不能试听」。本次保留接口错误，只有歌曲地址解析失败后才补查一次健康状态，并在音乐设置显示「已登录 · 播放异常」。旧服务器缺少新字段时仍可解码，不把未知播放状态当作失败，也不在每次搜索或播放前增加健康探测。
- 搜索结果的试听按钮增加获取地址时的进度状态、停止语义及完整点击区域，错误提示使用错误样式。原生 UI 回归实际发现歌曲选择区的中间留白未响应点击，已补上标签内部的 `contentShape`。错误不改变歌曲选择，仍可选择后添加。修订未宣称恢复 QQ 上游播放能力；需要站点音乐服务重新返回有效地址，并完成真实新歌曲试听后才能验收恢复。
- 最终单元测试 **91 项通过**，包含搜索结果 → 精确 MID 解析 → 服务失败诊断 → 继续选择、新旧状态接口兼容，以及取消后清除加载状态且不额外探测的回归。日志 `/private/tmp/yezi-music-search-fix-unit-complete-20261017.log`，结果 `/private/tmp/YeziMusicSearchFix-unit-complete-20261017.xcresult`。
- 新增原生 UI 回归 **1 项通过**：在搜索框输入 → 点击当前弹窗的试听按钮 → 显示接口及健康诊断 → 保持添加按钮禁用 → 点击歌曲选择区中部留白 → 添加成功并返回正文。使用确定性的离线服务失败夹具，**不代表真实 QQ 音频恢复**。日志 `/private/tmp/yezi-music-search-fix-ui-verified-20261017.log`，结果 `/private/tmp/YeziMusicSearchFix-ui-verified-20261017.xcresult`。最终 Release 构建通过，无源码编译告警；日志 `/private/tmp/yezi-music-search-fix-release-complete-20261017.log`。
- 本次修改尚未上传 TestFlight 或同步 GitHub；真实 QQ 新歌曲试听尚未恢复，仍需恢复服务端播放地址获取并验证。

## 2026-10-17 1.0（25）归档与上传

- 本轮输入、点击区域和加载优化已纳入 **1.0（25）**。签名归档成功，`codesign --verify --deep --strict` 通过，bundle ID 为 `me.aluvien.yeziblog`；归档中未包含演示启动开关、演示 URLProtocol 或测试 bundle。
- 归档 `/private/tmp/YeziApp-1.0-25.xcarchive`；归档日志 `/private/tmp/yezi-testflight-25-archive.log`。
- 2026-10-17 19:16（Asia/Shanghai）首次尝试上传时，Apple 返回 `exportArchive Failed to Use Accounts`，当时 Xcode 的 Apple Accounts 页面没有已登录账户；此次尝试结果为 `EXPORT FAILED`。首次尝试日志 `/private/tmp/yezi-testflight-25-upload.log`。
- 用户恢复 Apple Account 登录后，使用同一份已验证的签名归档继续上传。**2026-10-17 19:49（Asia/Shanghai）上传成功**，Apple 返回 `Upload succeeded`、`EXPORT SUCCEEDED`，当时状态为 `Uploaded package is processing`。成功上传日志 `/private/tmp/yezi-testflight-25-upload-after-login.log`。尚未将 Apple 后续处理完成或测试员可安装状态记为已验证。
- 本轮修复源码已同步 GitHub `main`，提交 `65e963e700df90fc7fd3cf07a9f6ada1d945e491`（`Fix music input and reduce loading work for build 25`）；本条上传记录随之后续文档提交同步。

## 2026-10-17 加载发热排查与优化（构建及模拟器回归通过，待真机能耗采样）

- 用户反馈：加载数据时手机明显发热。**目前没有真机 CPU、能耗或温度采样，不能认定已找到实机发热的唯一原因，也不能据此声称温度已经下降。** 下面列的是代码中能够确认的额外工作及对应修订。
- 絮语列表原为普通 `VStack`，会创建已加载列表中的所有卡片，屏幕外的图片和音乐信息也会启动加载。改为 `LazyVStack`，随滚动按需创建卡片；音乐卡片离开时只停止自身正在播放的音乐，避免其他卡片离开也触发全局播放器更新。
- 内容图片原来分别使用 `AsyncImage` 与原图数据加载器，后者持有无数量/容量限制的原图字典，并在视图 body 中反复 `UIImage(data:)`。现在统一使用图片加载器：按卡片显示尺寸生成缩略图（尺寸分桶、最高 2048 像素），在非主 actor 上用 ImageIO 解码，缓存已解码图片；NSCache 配置 32 MiB 成本目标及 96 张数量目标，不再持有无限增长的原图字典。视图离开时释放自身持有的图片。
- 远程内容图片最多同时加载 4 个；同 URL、同尺寸的并发消费者共用一次下载和解码。最后一个消费者取消时停止下载，排队中的取消项不会启动；清缓存会同时取消尚未完成的图片任务，防止旧任务重新填回缓存。
- 原发布完成回调与编辑器关闭回调都会刷新列表，单纯打开再退出阅读/编辑也会刷新。现在在服务器内容变动后于关闭页面时刷新一次；无变动返回、切换已加载的列表页面均复用现有结果。显式下拉刷新继续获取新数据。
- 文章筛选与搜索合并为一个可取消任务，非空搜索保留 350 ms 防抖；新刷新主动取消旧请求，原有 generation 检查继续阻止旧结果覆盖。加载成功的查询与正在加载的查询分开记录，避免取消后误把旧列表当成新搜索结果。
- `CreationTests.swift` 新增 7 项 XCTest 回归用例，覆盖缩略图/缓存、请求合并、并发上限、离开后取消、返回页面复用、搜索取消和取消后的重试。2026-10-17 19:08（Asia/Shanghai），最终源码在 iPhone SE（第三代）、iOS 27.0 模拟器完成 **88 项单元测试，0 失败**，包含原有 81 项及新增 7 项。日志 `/private/tmp/yezi-loading-fix-unit-verified-20261017.log`；结果包 `/private/tmp/YeziLoadingFix-unit-verified-20261017.xcresult`。
- 在完整构建恢复前，已用实际源码及异步 URLProtocol 完成 9 组独立组件检查，包括下载与排队取消、进行中清缓存及取消查询恢复，全部通过；独立组件记录不替代上面的原生测试，也不代表真机能耗结果。
- 自动审批服务恢复后，最终源码的模拟器测试构建和 iOS Release 构建均成功。Release 日志 `/private/tmp/yezi-loading-fix-release-verified-20261017.log`，未发现编译警告或错误；Release 可执行文件未包含演示域名、演示 URLProtocol 或本轮 UI 测试启动开关。工程 plist、UI scheme XML 与 `git diff --check` 均通过。
- 当前可用设备为模拟器，登记的物理 iPhone 均处于 unavailable 状态，尚未进行真机 Instruments 能耗/温度采样。
- 本轮修改已纳入 1.0（25）签名归档，TestFlight 上传状态见本页发布记录。

## 2026-10-17 音乐后输入与管理入口点击修复（原生界面回归通过）

- 用户反馈：选择音乐后正文无法继续输入；管理选项只能点击文字，整行留白无效。
- 输入区：最低书写高度由 `MarkdownWritingView` 的原生 UITextView 实际尺寸承担，避免仅在外层 frame 留白；絮语、文章及共用控件的关于页面均采用该尺寸方式。选择音乐后等待选择页关闭，再恢复正文焦点；取消选择不会强制弹出键盘，原文和光标不作重置。
- 原生输入桥接：保留同步收起键盘，仅将界面更新期间触发的文本/撤销状态回写延后，避免 `updateUIView` 内同步发布状态；撤销状态只有实际变化时才发布。最初通过的 UI 回归暴露了状态更新警告，第一种异步收键盘处理导致取消后键盘回弹，现已改为协调器保护并复测通过。
- 管理入口：在 NavigationLink 的 label 内为整行与卡片设置矩形点击区域，覆盖文字间、箭头前和四周内边距；文件入口、四个设置卡片、六个内容/站点列表入口及退出行均处理。
- 新增独立 `YeziInteraction` scheme 与 `YeziAppUITests/InteractionTests.swift`，覆盖音乐选择后输入、再次点击空白书写区，以及管理列表与卡片的留白点击。UI 测试使用 DEBUG 下独立临时草稿目录及空白絮语样本，不访问生产 API，不使用真实草稿；这些启动开关不进入 Release。
- 2026-10-17 18:58，**3 项原生 UI 测试全部通过**，包括 5 个管理卡片和 6 个列表入口的留白点击。日志 `/private/tmp/yezi-loading-fix-ui-20261017.log`；结果包 `/private/tmp/YeziLoadingFix-ui-20261017.xcresult`。
- 最终键盘同步调整后，19:07 单独重跑完整音乐输入链路通过：选择稻香 → 输入文字 → 再开选择器并取消 → 键盘收起 → 点击正文留白 → 继续输入，原文保留；运行日志未再出现 `Modifying state during view update` 或 `Publishing changes from within view updates`。日志 `/private/tmp/yezi-loading-fix-input-verified-20261017.log`；结果包 `/private/tmp/YeziLoadingFix-input-verified-20261017.xcresult`。已人工查看并保留[原生输入截图](interaction-fixes-20261017/music-input.png)。
- 最终 88 项单元测试、Release 构建及工程格式校验均通过，详见上一节。本轮不涉及真实 QQ 音频播放或生产账户写入的端到端验证。
- 本节修订已纳入 1.0（25）签名归档并成功上传，详见本页发布记录；下面的 1.0（24）记录保留为历史。

## 2026-10-15 主导航调整与二级页面统一（上一轮）

主导航调整为 **絮语、文章、评论、管理**。文件从底部移入管理首页的独立入口；[完整原生截图](interaction-20261015/index.html) 已按此次调整更新。下方第一轮改版与 10 月 3 日记录保留为历史基线。

- 评论：底部直接进入，访客、时间、来源、审核状态、正文和已有回复分层显示；常用的通过、回复操作直接可见。回复窗口统一卡片和底部保存区域，失败保留输入，避免重复提交。
- 管理：文件管理作为靠前的独立卡片；基础信息、音乐、外观、GitHub 更新继续使用统一设置入口。作品、分类标签、引用资料、阅读缓存、参考文章阅读、关于页面及编辑窗口统一暖白、深绿、语义字体、留白、圆角和触控区域。
- 编辑：作品、分类标签、引用编辑、评论回复和视频插入沿用固定保存区；关于页面使用支持光标、选区、撤销重做及预览的 Markdown 编辑器，媒体插入回到原选区，音乐入口复用新版选择器。
- 阅读与概览：概览及最近发布入口接入新版文章阅读和絮语编辑；最近发布去除有效音乐指令文本，纯图片絮语显示照片数量，音乐内容优先使用歌曲和歌手信息。
- 小屏与深色：逐页检查 375pt 模拟器上的主导航、文件、设置、作品、分类标签、引用、回复和编辑页面；补充絮语、评论与关于页面的深色截图。此处的截图确认不等同于真实点击回归。

验证结果：

- 最终 81 项测试通过，0 失败。日志 `/private/tmp/yezi-unified-tests-final.log`；结果包 `/private/tmp/YeziInteractionDerivedData/Logs/Test/Test-YeziApp-2026.10.15_15-01-45-+0800.xcresult`。
- 本轮新增覆盖评论回复/删除失败保留状态并可重试、阻止重复评论操作、媒体插入的 UTF-16 选区与撤销，以及不可编辑文本控件的插入保护。
- Debug 模拟器与 Release iOS 未签名构建均通过；Release 日志 `/private/tmp/yezi-unified-release-final.log`，无编译警告或错误。
- `git diff --check`、工程文件与 Info.plist 格式校验通过；Release 二进制检查不包含离线预览开关、演示域名或 fixture URLProtocol。
- **2026-10-15 15:19（Asia/Shanghai）：本节修订已随 1.0（24）上传 TestFlight。** Apple 返回 `Upload succeeded`、`EXPORT SUCCEEDED`，上传完成时状态为 `Uploaded package is processing`；尚未确认处理完成或测试员可安装。签名归档核验通过，构建号确认为 24，正式包未包含离线演示标记。归档 `/private/tmp/YeziApp-1.0-24.xcarchive`；归档日志 `/private/tmp/yezi-testflight-24-archive.log`；上传日志 `/private/tmp/yezi-testflight-24-upload.log`。下方 1.0（23）的上传记录属于更早的第一轮改版。

验证边界：演示数据与线上账户隔离；本轮未执行线上创建、删除、设置更新或 GitHub 同步。相机、系统照片选择、生产账户登录和真实 QQ 音频仍保留实机验证边界。

## 2026-10-15 阅读、写作与管理第一轮改版（历史）

第一轮主导航为絮语、文章、文件、管理；当前导航与截图以本文件开头的最新修订为准。

- 絮语：文字、照片、音乐快捷入口；压缩最近草稿卡，保留首屏正文；搜索按需展开，支持类型筛选。
- 文章：列表点开阅读，独立编辑按钮；右下角写作入口。Markdown 工具作用于当前光标或选区，支持中文/emoji、撤销重做、编辑/预览切换，键盘上方固定工具栏。
- 草稿：正文结束编辑及重复文本回调不再产生无效修改；打开、聚焦、关闭而未改动时，不创建本机草稿。
- 文件：分类、已加载内容搜索、排序、上传、详情、引用和分享；先通过现有会话下载原文件，Markdown 原生渲染，其余使用 Quick Look；下载失败与取消正确区分。
- 管理：常用入口集中为基础信息、音乐、外观、GitHub 更新。设置页使用固定保存区域，未修改时禁用保存，加载失败可重试。
- 视觉：暖白和深绿统一色板；核对 375pt 小屏、深色、中文键盘、PDF 和图片预览。

验证结果：

- 78 项测试通过，0 失败。日志 `/private/tmp/yezi-interaction-tests-download.log`；结果包 `/private/tmp/YeziInteractionDerivedData/Logs/Test/Test-YeziApp-2026.10.15_13-41-07-+0800.xcresult`。
- 新增覆盖：UTF-16 选区格式化、行内光标、多行列表、标题光标、文件分类、真实 UITextView 撤销/重做、重复回调不生成草稿、下载原字节、HTTP 失败和请求取消。
- 最后仅调整撤销/重做禁用外观与设置页文案，随后 Debug 模拟器及 Release 真机构建均通过。日志 `/private/tmp/yezi-interaction-build-final.log`、`/private/tmp/yezi-interaction-release.log`。
- `git diff --check`、工程文件格式校验通过。Release 二进制未包含演示域名、启动开关或 fixture URLProtocol。
- 2026-10-15 13:53（Asia/Shanghai）：1.0（23）签名归档并上传成功，Apple 返回 `Upload succeeded`、`EXPORT SUCCEEDED`，当时状态为 `Uploaded package is processing`。归档 `/private/tmp/YeziApp-1.0-23.xcarchive`；归档日志 `/private/tmp/yezi-testflight-23-archive.log`；上传日志 `/private/tmp/yezi-testflight-23-upload.log`。尚未把 Apple 后续处理完成或测试员可安装状态记为已验证。

验证边界：截图由独立离线演示与本地样本生成，不代表线上账户、相机、系统照片选择或 QQ 真实音频的端到端验证。没有对生产站点执行创建、删除、配置更新或 GitHub 同步。模拟器的页面启动和截图、业务测试与真实文本控件测试分开记录；没有将启动截图当成实际点击回归。

## 2026-10-03 设计与执行

- 主代理：GPT-6 Astra，负责方案、视觉样稿、最终验收与整合。
- 执行：用户指定 GPT-6.1 Sol / High；执行代理 Pascal（01a0fd90-3a65-79c3-be2a-a5d78ff957f9）。
- 设计基线：`moment-first-redesign.md`。
- 可点击样稿：`moment-first-preview.html`，演示数据，无线上发布。
- 源码由执行代理独占完成，已交还主代理并结束执行代理；主代理维护 `docs/design/` 并完成独立复测与最终整合。

## 验收记录

2026-10-03 验收结论：设计与本次代码实施完成，主代理独立复测58项全部通过。以下区分自动回归、源代码审查和真实模拟器截图；离线演示不作为线上服务已验证的证据。A02的原生交互部分和末尾所列真机边界没有假报通过。

| 项目 | 状态 | 证据/待处理 |
|---|---|---|
| 导航与一键记录 | 实现/静态确认 | A01、A17：四 tab 默认想法；文字/照片/音乐共用编辑器；管理原路由保留；首页截图验证 |
| 视觉、键盘、深色、小屏 | 截图确认；保留交互边界 | A02、A20：375pt、390pt、iPhone Air、深浅色、accessibility-medium；系统输入区域上方工具条可见；见下方限制 |
| 图片与发布资格 | 回归通过 | A03–A06：四类 payload、9 图上限、真实失败后定向重试、在途移除晚回调、最多2并发、PNG透明/2048下采样；截图发现的网格溢出已修正 |
| 草稿恢复和站点隔离 | 回归通过 | A07–A08：重建store恢复、文件缺失、损坏邻居、revision、站点隔离；原生反复终止/启动后演示草稿仍在 |
| 音乐及旧内容兼容 | 回归通过 | A09–A10：generation、手动链接、多音乐与未知Markdown、完整引用、替换移除及停止；精确MID和相对缓存URL均有测试；真实音频未联网验证 |
| 提交一致性与失败恢复 | 回归通过 | A11–A12、A16：双击只发一次、明确失败、超时不重发、终态不复活、在途新输入保留；待确认不显示假成功 |
| 文章与 API 回归 | 回归通过 | A13–A15：必需字段、直接/包裹对象、真实decoder分页、POST→PATCH、已发布状态保护、封面、预览与payload一致 |
| 构建、测试、权限 | 构建与58项回归通过 | A18–A19：Debug/Release simulator构建；执行代理及主代理独立设备均58项0失败；Debug显式定义DEBUG，Release二进制不含preview站点/URLProtocol字符串 |

## 结果

执行代理已完成实现并交还源码；主代理独立审查源码、协议、测试内容，并以真实模拟器截图要求和复核修正。最终58项完整suite在第二台独立设备再次通过。尚未进行真机/线上写操作验收，未提交、推送或发布到商店。

## 监督中发现的风险

以下问题已由执行代理修正，主代理已复核最终代码及对应回归/截图证据：

1. 发布/舍弃后的延迟保存与 `onDisappear` 不得使草稿复活。
2. 清空旧草稿后不得恢复之前的非空内容；一个损坏文件不得隐藏其他健康草稿。
3. 文章首次加载失败后，重试按钮必须仍可操作，编辑与发布保持禁用。
4. 想法引用必须保留完整快照，不能使用只有文章 payload 才能补全的 compact 标记。
5. QQ 精确播放接口返回的 `key: qqvip:<MID>` 必须正确匹配，不可被新的 MID 校验拒绝。
6. 多个音乐卡片不得同时播放；试听结束、失败和离开页面后须停止并恢复可理解状态。
7. 选择已有封面附件必须真正修改封面，不得误当正文附件插入。
8. 图片大图预览须完整适配，不沿用缩略图裁切；本地清理限本草稿拥有的文件。
9. 深色主题实心绿色按钮不能沿用白字（2.29:1），改为 `onAccent` 深色文字（7.91:1）。
10. Debug 构建必须实际带 `-D DEBUG`，否则离线演示会被编译裁除；Release 不允许该标志。
11. 上传失败重试测试必须真实触发失败；移除晚到回调测试必须先等到上传启动，避免空测通过。
12. “发布结果待确认”退出查看列表不能触发“已发布”成功横幅。
13. 恢复本机文章时，远端已发布状态必须覆盖过时的本机 draft 状态，防止误下架。
14. 原生 375pt 截图暴露缩略图 `scaledToFill` 横向撑开网格、遮挡删除按钮；修正为单元格明确尺寸后已复拍确认正常。
15. 大字号媒体工具不能按单个汉字挤压换行；图片需减少列数，工具使用上下布局。
16. 文章预览与提交共用图片序列化内容，避免新增照片只出现在提交 payload 而预览遗漏。
17. 网站缓存音乐接口返回站内相对音频 URL，不能因缺少绝对 scheme 而误判不可试听。

## 原生验收环境

- Xcode 27.0 / iOS 27.0 Simulator，最低部署目标仍为 iOS 17。
- 执行代理测试设备：iPhone Air。
- 主代理独立小屏设备：`Yezi Creation QA 375`，iPhone SE (3rd generation)，375pt，UUID `A74DD15B-27F1-4B92-B93D-F3340B20DE23`。
- 主代理独立常规设备：`Yezi Creation QA 390`，iPhone 16e，390pt，UUID `ECD68397-2FB8-4195-9BCF-35A2F205F7E7`。
- 使用 DEBUG 专用 `--creation-preview`，站点 `https://creation-preview.invalid`，全部请求由本地 URLProtocol 处理；不发布到真实站点。
- 实机相机、真实 QQ 播放可用性、线上网络时延不能由离线 fixture 证明，需在最终结论中区分。

## 已有测试证据

执行代理串行运行完整 suite，最终回归 58 项（新增33 + 原有25），0失败：

```sh
xcodebuild -project YeziApp.xcodeproj -scheme YeziApp \
  -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=499FCB18-FC0B-4C89-A0F7-28345BEBE2CB' \
  -derivedDataPath /private/tmp/YeziCreationDerivedData \
  -parallel-testing-enabled NO \
  -resultBundlePath /private/tmp/YeziCreationTests-audio-final-20261003.xcresult \
  CODE_SIGNING_ALLOWED=NO test
```

- 日志：`/private/tmp/yezi-creation-audio-final-tests.log`，`TEST SUCCEEDED`。
- Debug构建：`/private/tmp/yezi-creation-debug-build.log`，`BUILD SUCCEEDED`。
- 最终Release构建：`/private/tmp/yezi-creation-audio-final-release.log`，`BUILD SUCCEEDED`；仅有未使用 AppIntents 的元数据提取提示。
- 最初并行测试 runner 在 iOS 27 克隆设备上失败；已改共享scheme为串行，完整重跑成功，不将失败运行视为通过。
- 主代理已执行 `git diff --check`，并检查 Release 二进制未保留 DEBUG fixture 的域名或 URLProtocol 字符串。

主代理在独立390pt设备复跑最终构建的全部测试，不复用子代理结果冒充自己的验证：

```sh
xcodebuild -project YeziApp.xcodeproj -scheme YeziApp \
  -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=ECD68397-2FB8-4195-9BCF-35A2F205F7E7' \
  -derivedDataPath /private/tmp/YeziCreationDerivedData \
  -parallel-testing-enabled NO \
  -resultBundlePath /private/tmp/YeziCreationParentVerification-20261003.xcresult \
  CODE_SIGNING_ALLOWED=NO test-without-building
```

结果：`TEST EXECUTE SUCCEEDED`，58项0失败。日志 `/private/tmp/yezi-creation-parent-verification.log`；实际执行约3.6秒，另有Xcode启动设备/测试运行器耗时。

## 原生截图

查看 `native-review.html`，与可点击设计样稿 `moment-first-preview.html` 分开标示，避免将原型当成实现。

| 文件（`screenshots/`） | 主代理实际核对 |
|---|---|
| `native-feed-375-light.png` | 默认想法、三个创作入口、继续记录、四tab、浮动写想法 |
| `native-composer-375-light.png` | 三列图片不溢出，三个删除按钮均可见，本机保存、音乐卡、上下操作区 |
| `native-composer-375-dark.png` | 同样内容的深色对比与表面层级；实心按钮文字对比7.91:1 |
| `native-music-375-light.png` | 搜索/最近添加/手动输入入口、选择与试听独立、确认按钮 |
| `native-article-375-light.png` | 标题正文主导、发布设置与底部照片/音乐/格式 |
| `native-drafts-375-light.png` | 想法文章草稿、媒体数量、缩略图、明确本机标识 |
| `native-settings-375-dark.png` | 有固定字段标签的分类/标签/封面/地址与附件引用信息 |
| `native-composer-375-accessibility.png` | 大字号双列图片、上下媒体标签，没有单字挤压或横向溢出 |
| `native-composer-390-light.png` | 常规宽度与底部home indicator安全区 |
| `native-composer-air-light.png` | iPhone Air大屏排版、正文聚焦；此设备未显示软件键盘，不将其当键盘截图 |
| `native-composer-375-keyboard.png` | 媒体条抬到系统输入区域上方；截图含首次QuickPath系统教程，不冒充完整输入测试 |

## 明确未验证的边界

- Xcode 27 的 Device Hub 原生自动化读取持续超时，因此没有将截图启动参数当成真实点击/滚动/VoiceOver测试。原生画面通过 `simctl` 启动和截图，业务状态转换通过 URLProtocol 回归测试。
- 新建模拟器首次软件键盘出现 QuickPath 教程，未绕过系统界面；已观察到正确键盘安全区，但真实打字、选中、光标格式化、关闭键盘和相册返回等仍需真机验收。
- 没有调用线上创建/更新/删除 API，故生产 Cookie 过期、弱网的真实时序、相机授权、系统相册选9张大图和 QQ 真实音频可用性未声称端到端通过。
- 图片背景处理的源码和输出尺寸有测试；未对真实设备的峰值内存、相机原图编码和长时间运行做性能测量。
