# 想法优先改版 · 监督验收

## 2026-10-17 1.0（25）归档与上传

- 本轮输入、点击区域和加载优化已纳入 **1.0（25）**。签名归档成功，`codesign --verify --deep --strict` 通过，bundle ID 为 `me.aluvien.yeziblog`；归档中未包含演示启动开关、演示 URLProtocol 或测试 bundle。
- 归档 `/private/tmp/YeziApp-1.0-25.xcarchive`；归档日志 `/private/tmp/yezi-testflight-25-archive.log`。
- 2026-10-17 19:16（Asia/Shanghai）尝试上传 App Store Connect，Apple 返回 `exportArchive Failed to Use Accounts`，要求团队 `DR2TNGTRAJ` 的 App Store Connect 访问权限，结果为 `EXPORT FAILED`。随后核对 Xcode 的 Apple Accounts 页面，当前没有已登录账户，页面显示 `Sign In…`。**本次上传未成功，不能记为 TestFlight 已接收。** 上传日志 `/private/tmp/yezi-testflight-25-upload.log`。
- 已保留可重新上传的签名归档，待恢复 Xcode 的 Apple Account 登录及团队访问后，直接使用该归档继续上传，无需重做业务修复。最后一次成功上传仍为 2026-10-15 的 1.0（24）。

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
- 本节修订已纳入 1.0（25）签名归档，最后一次成功上传仍为下面记录的 1.0（24）。

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
