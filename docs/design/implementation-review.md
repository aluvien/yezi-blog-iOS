# 想法优先改版 · 监督验收

## 2026-10-24 TestFlight 1.0（34）发布

- 19:14（上海时间）通过 Xcode Organizer 上传成功，归档状态为 Uploaded to Apple / Build 34；Apple 尚需处理构建。正式分发日志确认 `aps-environment = production`，包含 Push Notifications。
- 本次包含下方此前标注本地未发布的字体、播放器与歌词、评论稳定性、加载及通知改动。iOS 单元测试 148 项、关键界面回归 6 项全部通过，结果分别为 `/private/tmp/yezi-build34-units.xcresult`、`/private/tmp/yezi-build34-ui.xcresult`。
- 配套网站通知代码通过 PR #50 同步；正式设备注册与 Apple 推送送达仍需在线部署后的真机联调，不以模拟器路由测试代替。

## 2026-10-24 iOS 通知接入（本地凭证已配置，待上线联调）

- 管理页新增原生通知设置：主动申请权限、新评论/QQ 音乐登录失效独立开关、设备测试通知。App 无新增后台轮询，相同绑定不重复提交，登出/切站点解除绑定。
- 网站配套实现于独立分支/worktree，包含 APNs ES256 签名、固定 topic、认证/CSRF 设备接口、持久化去重与退避队列、过期设备停用、会话和站点隔离。评论独立于 Telegram；QQ 音乐只对明确登录失效事件提醒，持久化去重，沿用网站现有健康检查。
- 单元测试 148 项、通知 UI 测试 3 项通过；网站测试 391 项通过、1 项跳过，通知专项 11 项通过；TypeScript、ESLint、网站生产构建与 App Debug / 未签名 Release 编译通过。
- 用户确认并提供 APNs 密钥，本地私有配置已引用原文件（0600、Git 忽略），文件已从 iCloud 下载，P-256 格式与本地 ES256 签名/验签通过。Team ID 沿用 App 的开发团队，尚未向 Apple 验证授权。未部署、推送 GitHub 或上传 TestFlight。通知 UI 测试使用离线预览路由，不能代替真实 Apple 推送与真机后台/冷启动验收。详见[接入与源码说明](../notifications.md)与[实际截图](notifications-20261024/settings.png)。
- 后续按用户指定合入本地 `/Users/aluvien/Develop/Website/yezi-blog`，保留原有改动并配置其私有环境文件。该目录类型检查、全部 255 项测试和生产构建通过；隔离数据库的实际服务启动验证中，通知状态接口认证返回 200 / configured，未认证返回 401，三个通知表迁移成功。验证进程已关闭，尚未注册真实设备或验证线上送达。

## 2026-10-24 絮语评论展开稳定与点击范围（本地，未发布）

- 去掉评论展开／收起时的整行高度动画，并对异步加载开始、结果提交和结束使用禁用动画的事务，避免加载过程叠加行高动画。加载结果的评论、分页、计数与 loading 状态一起提交；旧加载代次的错误不再覆盖新状态。
- 评论入口保留原文楷、字号、颜色及右对齐，透明点击区域至少 88×44 点，并明确 contentShape；无障碍值补充展开／收起状态。评论数据及回复仍使用原共享存储和接口。
- iPhone Air / iOS 27 UI 回归 **2 项通过**：`/private/tmp/yezi-comment-stability-ui.xcresult`。新增回归点击文字左侧透明范围，初次加载及连续三轮收起／展开后入口纵坐标偏差均不超过 2 点；现有回复发送与共享状态回归通过。diff 检查通过。[实际展开截图](comments-stability-20261024/expanded.png)使用离线预览数据，尚未真机验收；未上传 GitHub / TestFlight。

## 2026-10-24 悬浮播放器超长文字往返滚动（本地，未发布）

- 根据用户修正，迷你播放器的超长歌曲名／歌词取消省略号，保留第 3 宽歌词确定的卡片宽度。播放时仅溢出的文字以每秒 20 点左右往返，两端各停留 1.2 秒；歌词更换从开头重新展示。暂停保留滚动位置，恢复继续；短文字不启动时间线。
- 滚动在文字子视图内以最高 30fps 更新，不向列表发布逐帧状态。文字测量仅在文本／字号变化或首次出现时进行。卡片隐藏、后台和减少动态效果均停止滚动；减少动态效果时静态显示开头，完整文字保留在播放器按钮的无障碍值中。
- 算法测试 2 项通过：`/private/tmp/yezi-mini-scroll-unit.xcresult`，包含宽度规则、往返边界及端点停留。UI 回归 2 项通过：`/private/tmp/yezi-mini-scroll-ui.xcresult`，确认暂停／seek／滚动过程卡片宽度不变及搜索隐藏、跨页面播放器行为；diff 检查通过。[滚动前](mini-content-width-20261024/scrolling-start.png)与[滚动后](mini-content-width-20261024/scrolling-lyric.png)实际截图已目检，尾部文字可显示且无省略号。
- 使用模拟器离线示例与静音音频，未测量真机能耗。未上传 GitHub / TestFlight。

## 2026-10-24 按第 3 宽歌词固定悬浮播放器宽度（本地，未发布）

- 按迷你播放器实际文楷字号测量整首歌词，排除最宽的两句，以第 3 宽作为文字参考宽度；不足 3 句用最宽句，空白行不参与。无歌词时按歌曲名／歌手的较宽者决定。保留封面、间距、内边距，以及屏幕／写作按钮避让上限；超出单行省略。
- 测量结果存入视图状态，只在歌曲信息、整首歌词或动态字号变化以及视图首次出现时更新；进度、当前歌词句、播放暂停不会重新测量或改变参考宽度。歌词异步加载完成允许从资料回退宽度调整一次，旋转与屏幕可用空间变化仍按上限适配。
- 新增算法单元测试 1 项通过（包含实际字宽排序、不足 3 句、单句、空白／无歌词及字号变化），结果 `/private/tmp/yezi-third-lyric-unit.xcresult`。界面回归 2 项通过，结果 `/private/tmp/yezi-third-lyric-ui.xcresult`，断言播放、暂停及 seek 到较长歌词后的宽度相同，并验证写作避让、阅读／管理共享和搜索隐藏；diff 检查通过。
- 实际运行截图：[固定宽度歌词](mini-content-width-20261024/fixed-lyric.png)、[相同宽度暂停状态](mini-content-width-20261024/fixed-paused.png)。模拟器离线示例数据，不构成真机温升或能耗验证。未上传 GitHub / TestFlight。

## 2026-10-24 悬浮音乐卡片按内容收宽与歌词字体（本地，未发布）

- 移除左下角播放器固定宽度与文字撑满设置，按封面和两行文字自然收宽；保留原先最大宽度及写作按钮避让。原生玻璃胶囊、旋转封面、点击展开及滚动隐藏行为不变。
- 普通歌曲卡片、文章内歌单卡片的歌词改用既有宋体，保持原字号、颜色和单行省略。头像名字继续宋体，折叠歌曲及歌词继续文楷；迷你播放器与完整歌词页面字体本轮不变。
- iPhone Air / iOS 27 模拟器界面回归 **2 项通过**：`/private/tmp/yezi-mini-content-width.xcresult`。验证歌词替换及暂停回退、短歌名卡片宽度小于 190 点、与写作按钮不重叠、阅读及管理共享播放器、搜索隐藏和点击展开。`git diff --check` 通过。
- 实际运行截图：[暂停／短文字](mini-content-width-20261024/paused.png)、[播放／歌词](mini-content-width-20261024/playing.png)。使用离线预览数据和静音音频，未验证真机或外部音乐服务；未上传 GitHub / TestFlight。

## 2026-10-24 絮语名字与折叠音乐垂直居中（本地，未发布）

- 用户确认头像后的名字用宋体（既有 `NotoSerifSC-Regular`），折叠音乐及其歌词用文楷（`LXGWWenKai-Regular`），不能为对齐而将名字改成文楷。两侧使用 15 点字号和至少 32 点行高，外层显式垂直居中；不使用固定像素偏移。保留播放／暂停与歌词替换行为。
- 前一版名字也使用文楷时，iPhone Air UI 回归通过：`/private/tmp/yezi-music-alignment-still.xcresult`；[当时截图](player-lyrics-20261024/folded-centered.png)仅为历史记录。用户本次纠正后已恢复名字宋体，通过 Swift 语法解析及 diff 检查，尚未重拍或上传。

## 2026-10-24 歌词同行与紧凑全局播放器（本地，未发布）

- 普通音乐卡片播放时用当前歌词替换歌手所在的第二行，不再添加第三行；没有当前歌词及暂停时回退歌手。折叠音乐文字改为文楷，播放且有歌词时仅显示歌词，保留原生按钮点击播放／暂停。封面、歌曲名与独立播放控制保持。
- 展开歌词后只保留可滚动歌词列表，不再重复显示固定当前句；右上角收起按钮恢复单行当前句。上一首、播放／暂停、下一首移到封面与歌曲信息旁，图形缩为 13/17 点，各保留完整 44 点矩形点击区域。播放模式放到导航栏原生菜单。
- 文章歌单卡片将模式按钮放在播放按钮左边，本地切换顺序／随机；播放中的歌曲不重启，后续切歌使用新模式。歌曲名后同排显示“等 N 首”，N 为接口歌单总数；移除另起一行的序号与模式文本，保留原生横向分页及原有按需加载。
- 左下角播放器改为原生 glass 胶囊，封面左侧旋转、右侧两行歌曲信息，歌词同样替换歌手行。通过实际写作按钮宽度限制胶囊宽度，与右下角按钮水平对齐并避让。导航子页面与独立阅读弹层共用播放状态；滚动时收起，静止 300ms 后恢复；搜索、键盘、编辑和完整播放控制器优先隐藏。隐藏移除封面视图，旋转随离屏停止，未新增网络轮询。
- 单元测试 **142 项通过**：`/private/tmp/yezi-compact-lyrics-unit-final.xcresult`。最终界面回归 **7 项通过**：`/private/tmp/yezi-compact-lyrics-final.xcresult`，涵盖歌单模式／横滑、歌词替换及暂停回退、展开收起及 seek、悬浮按钮避让、试听恢复、阅读与管理子页共享、搜索隐藏、深色大字体。另补验模式切回顺序且不自动播放 1 项通过：`/private/tmp/yezi-compact-mode.xcresult`。首轮发现测试标识覆盖和快速划过两页，已修正容器标识及采用明确单页拖动；小图形点击区域已明确为完整矩形。最终补充当前歌曲跨列表的队列／站点上下文隔离；切换模式不影响尚未从此卡片播放的其他队列，同一模式不重复重置随机历史。对应单元回归通过，最后歌单与歌词两项 UI 复测通过：`/private/tmp/yezi-compact-context-ui.xcresult`；清晰截图补拍回归 1 项通过：`/private/tmp/yezi-compact-lyrics-clean.xcresult`。
- Release 无签名模拟器构建通过：`/private/tmp/yezi-compact-lyrics-release-final.log`；plist 与 diff 检查通过。[实际运行截图](player-lyrics-20261024/index.html)。仍使用离线示例歌词与本地静音音频；不构成真机能耗或外部平台播放验证。当前 TestFlight 1.0（33）不包含本节及上轮未发布的媒体卡片修改。

## 2026-10-24 文章歌单、视频直接展示与悬浮封面（本地，未发布）

- 文章歌单卡片此前只查询用户歌单目录，无法显示任意嵌入歌单的内部歌曲。现在直接读取 `playlist-metadata`，复用既有分页和会话缓存；展示歌曲名、歌手与封面，用原生分页左右切换。顺序模式先显示第一首，随机模式从已返回歌曲中选取初始歌曲，不为抽取初始曲而一次加载全部页。临近当前页末尾再续载；封面只创建当前和相邻项，避免同时解码整页图片。浏览不自动播放，已从卡片开始播放时滑动同步切歌，播放控制器切歌也同步卡片；资料失败可重试。
- 阅读视频直接创建外部 WKWebView 或原生 VideoPlayer，不再多套一层“播放视频”按钮。原生视频准备资料及控件而不调用 play，外部视频沿用要求用户操作才能播放的配置。原生视频实际开始播放时暂停音乐，离开阅读停止并销毁视频资源；加载失败保留重试。没有取得外部平台真实播放成功的证据。
- 全局底部条改为左下角圆形歌曲封面按钮，原生 glass 样式，与右侧写作按钮水平对齐，点击展开既有播放控制器。取消原先整行 inset 及写作按钮向上避让。仅小封面用局部 TimelineView 在播放时旋转，30fps 上限；暂停、后台、减少动态效果、控件离屏与展开控制器时停止，不用定时器发布整个列表状态。
- 本轮完整单元测试 141 项通过：`/private/tmp/yezi-media-cards-unit.xcresult`；最终 4 项界面测试通过：`/private/tmp/yezi-media-cards-ui-final.xcresult`，覆盖顺序/随机资料展示、横滑切换、播放中切歌、无额外视频入口、悬浮封面对齐及展开、试听恢复、长代码展开与原生分享。Release 无签名模拟器构建通过：`/private/tmp/yezi-media-cards-release.log`，plist 与 diff 检查通过。真实能耗与外部视频服务仍未验证。
- [本轮实际运行截图](player-cards-20261024/index.html)，模拟器离线资料及静音音频夹具。本节修改未上传 GitHub / TestFlight，已上传的 1.0（33）不包含本节修改。

## 2026-10-24 TestFlight 1.0（33）上传成功

- 14:14（Asia/Shanghai）Xcode Organizer 明确显示 `App upload complete`、`YeziApp 1.0 (33) uploaded`；归档列表状态为 `Uploaded to Apple`，Submission Status 构建号为 33。使用现有账号上传，未要求重新登录。Apple 后续处理完成及测试员可安装状态尚未核验。
- 包含下方自动续载、管理页缓存、数据计算复用与交互调整，以及关于页面常驻 Markdown 说明文字移除。原节「本地，未发布」描述保留为实现时状态，这些修改已包含在构建 33。未同步 GitHub。
- Release 签名归档 `/private/tmp/YeziApp-1.0-33.xcarchive`；日志 `/private/tmp/yezi-testflight-33-archive.log`，`ARCHIVE SUCCEEDED`。核验包内版本为 1.0（33），`codesign --verify --deep --strict`、plist 和 diff 检查通过。关于说明删除的针对性 UI 回归另通过 1 项：`/private/tmp/yezi-about-hint-removed.xcresult`。
- 上传日志 `/private/var/folders/zm/d8g9437n3c3g9mjxkmgtt6dr0000gn/T/YeziApp_2026-10-24_14-13-13.053.xcdistributionlogs/`。本次上传不改变尚无真机能耗测量的验证限制。

## 2026-10-24 自动续载、管理缓存及交互调整（本地，未发布）

- 絮语列表底部出现时自动请求下一页，无需点击；保留加载中保护、末页停止、ID 去重与取消检查。下一页失败保留已显示内容并提供明确重试，不自动反复请求。UI 测试通过滚动确认第二页实际出现，请求计数测试覆盖并发续载和失败后重试同页。
- 管理首页状态改为由认证 API 客户端持有，避免视图重建后退回“我的小站”。站点名、说明和图标是公开身份信息，按完整站点根 URL 隔离保存在本机，重新启动可立即恢复；后台完整设置、密钥与仪表盘数据不写入这个持久缓存。基础信息保存成功后立即更新身份信息；切换站点不会混用。
- 统计保留在当前认证会话内，30 秒内再次进入复用；过期进入、相关数据变更后进入、主动下拉刷新时更新。没有新增轮询定时器。刷新时保留旧数值，统计区域始终占位，避免整张卡片突然变高。退出或认证失效清除私有统计；失败保留最近成功显示。测试覆盖首次并发进入只发生设置与统计各一次请求、重新进入零额外请求、统计失效仅增加一个请求，以及跨站点身份隔离和失败保留。
- 确认并减少滚动时的重复工作：絮语 Markdown、折叠音乐、标签、富文本及日期展示按内容和日期预先计算，未变化的刷新复用同一展示对象；原来的逐条评论计数发布合并为一次发布。没有以修改缓存替代真实能耗测量。
- 同轮按已确认需求调整：内容入口统一称“随笔”，页首显示“随笔与杂记 · 共 N 篇”（未筛选查询的服务端总数），取消顶部分割线；管理页去掉大标题，网站图标读取后台配置，缺失时使用原生 globe；评论与音乐同页选项卡支持横滑，不给底部导航或设置选择器添加该手势。原生 UISegmentedControl 使用局部界面字体，保留原生交互；日期、标签与评论入口使用文楷。
- 外观页删除旧版式选择及编辑版专属设置，保存时排除已退休字段；关于页空正文提示在聚焦时消失，单独聚焦不产生修改或保存。后续根据截图补充删除“正文”下方常驻的“支持 Markdown，选中文字即可排版。”说明，同时不保留空副标题占位。
- 验证：最终完整单元测试 **141 项、0 失败**，`/private/tmp/yezi-loading-unit-verified.xcresult`；两轮 UI 测试各 **4 项、0 失败**，`/private/tmp/yezi-loading-ui.xcresult` 与 `/private/tmp/yezi-loading-ui-final.xcresult`，包含自动续载、管理再次进入、评论横滑、搜索/图库/阅读回归、关于聚焦、外观及深色大字体。Release 无签名模拟器构建通过，`/private/tmp/yezi-loading-release.log`；plist 和 diff 检查通过。
- 能耗限制：没有连接且可用的物理 iPhone。模拟器 Time Profiler 尝试仅取得初始 Stackshot，没有可用的连续 CPU 样本，不能据此报告 CPU 降幅、温度改善或确认用户手机发热根因。真实网络图片、音乐及手机能耗仍需真机验证，不能称发热已经解决。
- [本轮实际运行截图](loading-review-20261024/index.html)：375pt 模拟器离线夹具，管理页图标缺失时展示原生后备图标，非线上站点截图。本节修改未上传 GitHub / TestFlight，当前已上传的 **1.0（32）不包含本节修改**。

## 2026-10-24 TestFlight 1.0（32）上传成功

- 03:41（Asia/Shanghai）Xcode Organizer 明确显示 `App upload complete`、`YeziApp 1.0 (32) uploaded`；归档列表为 `Uploaded to Apple`，Submission Status 构建号为 32。使用现有登录账号完成上传。Apple 后续处理及测试员可安装状态尚未核验。
- 本次包含下方「图片预览下滑关闭」与「播放、歌词、阅读与会话缓存」两节全部本地修改；其「未发布」描述记录实现时的状态，本次均已随构建 32 上传。未同步 GitHub。
- Release 签名归档 `/private/tmp/YeziApp-1.0-32.xcarchive`，日志 `/private/tmp/yezi-testflight-32-archive.log`；`ARCHIVE SUCCEEDED`，包内版本 1.0（32），`codesign --verify --deep --strict` 通过；plist 与 diff 检查通过。
- 分发日志 `/private/var/folders/zm/d8g9437n3c3g9mjxkmgtt6dr0000gn/T/YeziApp_2026-10-24_03-40-05.587.xcdistributionlogs/`。本次上传不改变下方记录的真机崩溃、能耗测量与外部视频服务验证限制。

## 2026-10-24 图片预览下滑关闭（本地，未发布）

- 共用全屏图片预览添加 UIKit 单指下拉手势，图片随手指移动；达到距离或速度阈值后关闭，短拖或取消时弹性回位，并适配减少动态效果。只接受向下且以垂直方向为主的手势，翻页过程中不触发关闭，保留原生左右分页和「完成」按钮。
- 适用于絮语与编辑器中使用该共用预览的图片。新增下拉短拖回弹、快慢下滑关闭、关闭后重新打开回归，并复测连续快慢左右翻页、末页回弹、取消翻页和图片重载。两项模拟器 UI 测试通过：`/private/tmp/yezi-gallery-dismiss.xcresult`；日志 `/private/tmp/yezi-gallery-dismiss.log`。未上传 GitHub 或 TestFlight。

## 2026-10-24 播放、歌词、阅读与会话缓存（本地，未发布）

- 字体按确认的分工恢复：界面、标题和歌曲资料使用思源宋体；正文、编辑区、歌词、日期和播放时间使用文楷；代码保留等宽字体。移除絮语和文章列表每条内容的横分割线，保留滑动编辑、删除。
- 音乐列表整行点播，歌曲和歌手分居同一行两端，移除行尾播放按钮，正在播放的行高亮。实际截图发现标题会挤掉歌手后，改为给歌手独立宽度并在 375pt 小屏复测。
- 歌词读取网站 `lrc`，支持多时间标签、毫秒、排序和进度定位；沿用现有播放进度观察器，无新增歌词定时器。当前行、展开列表及文章音乐卡片共用播放器状态；暂停不自行推进，手动跳转仍定位。会话内复用歌词响应，取消旧曲任务，歌词失败独立重试。
- 播放安全修正：AVPlayerItem KVO、播放进度、锁屏控制及 MediaPlayer 封面回调显式使用 Sendable 边界，再回 MainActor 更新界面，避免 Objective-C 工作线程回调继承主线程隔离。播放错误改为卡片内提示，修复后台折叠音乐在播放器上弹出重复警告、遮住重试入口的问题。模拟器播放失败重试已通过，**没有取得用户手机的原始崩溃堆栈，尚不能认定手机闪退的唯一根因或真机问题已经解决**。
- 文章阅读接入真实音乐组件、按需启动的 Bilibili/YouTube WKWebView 和原生 AVPlayer 视频；离开页面停止视频。提供加载失败与重试。长代码与网站一致按超过 16 行启用折叠，折叠高度最多 320pt，长行横向滚动，复制保留完整原文；编辑器预览复用该代码组件。
- 阅读工具栏采用系统 ToolbarItemGroup，让编辑和分享位于原生胶囊。分享调用网站已有 POST `/api/posts/{id}/short-link`，缓存同篇文章短链接，再打开 UIActivityViewController；草稿禁用分享，无效响应不进入缓存，失败可重试。
- 视频插入识别 Bilibili/YouTube 分享文字、BV 号、短链接和 Bili 分 P，支持 YouTube watch/embed/shorts/live；多个结果必须选择，保存网站兼容的 `!video` 标记。失败保留输入。B23 采用无 Cookie 临时会话解析、限制重定向域名；外部平台实际播放仍受网络和平台权限影响。
- 内容列表、详情、评论、文件、管理首页及音乐资料使用有界的会话内缓存和请求合并；主动刷新、内容变更或音乐设置变更失效对应数据。管理设置子页进入仍刷新，存在未保存修改时不覆盖输入。无新增持久化管理缓存。原有请求计数测试覆盖重复进入、空结果、筛选、请求取消合并、刷新及定向失效。**没有真机能耗与温度测量，不将缓存改进等同于发热已经解决**。
- 验证：完整单元测试 **135 项、0 失败**，`/private/tmp/yezi-confirmed-unit-final.xcresult`。大屏字体、队列/试听恢复、歌词和视频文案插入 4 个场景通过，`/private/tmp/yezi-confirmed-media-ui.xcresult`；首次另有播放错误弹窗冲突和分享测试错误查询元素类型，分别修复产品交互与测试定位。375pt 上失败重试、歌词定位、深色大字、代码展开和原生分享 4 项 UI 测试全部通过，`/private/tmp/yezi-confirmed-media-small.xcresult`。最后补齐资料和评论详情日期字体后，Release 无签名模拟器构建再次通过，`/private/tmp/yezi-confirmed-release-final.log`；plist 与 diff 检查通过。
- [本轮实际运行截图](media-review-20261024/index.html)：均为模拟器离线夹具，歌词为测试文本、播放音频为本地静音 WAV；错误路径使用不可用地址，不代表真实 QQ 音乐服务或真实手机的验证结果。没有已连接且可用的物理 iPhone。本轮未上传 GitHub 或 TestFlight，已上传构建 31 不包含本节的新改动。

## 2026-10-24 TestFlight 1.0（31）上传成功

- 01:59（Asia/Shanghai）Xcode Organizer 明确显示 `App upload complete`、`YeziApp 1.0 (31) uploaded`；归档列表为 `Uploaded to Apple`，Submission Status 构建号为 31。使用现有登录账号完成上传。Apple 后续处理及测试员可安装状态尚未核验。
- Release 签名归档 `/private/tmp/YeziApp-1.0-31.xcarchive`，日志 `/private/tmp/yezi-testflight-31-archive.log`；`ARCHIVE SUCCEEDED`，包内版本 1.0（31），`codesign --verify --deep --strict` 通过。
- 包含下述内容字体统一、原生全屏图片分页，以及文章分类、日期、标签同排显示；验证证据见下一节。下述「本地，未发布」记录保留为当时状态，这些修改现已包含在构建 31。本次未推送 GitHub。

## 2026-10-24 内容字体与原生图片分页（本地，未发布）

- 内容标题使用内置 Noto Serif SC 的 Regular/SemiBold 字体实例；正文、摘要、评论回复及 Markdown 输入使用官方 LXGW WenKai Regular v1.530，随包附 OFL 许可。导航、菜单、日期标签与代码保持原有系统/等宽字体，支持动态字号。全文楷字体保留完整字库以覆盖生僻字，新增字体文件约 25 MiB。
- 文章阅读元信息改为「分类 · 日期 · #标签」同一个自然换行文本，空值不留下多余分隔符。
- 絮语与编辑器图片预览改为全屏 `UIPageViewController`。页面视图保持稳定，完成翻页后更新索引并保留当前/相邻页；相邻图片提前加载。远程图片复用既有有界解码缓存和请求合并，本地图片后台降采样到最多 2048 像素；缺少本地文件时回退远程。重试保持旧图，退出/淘汰页面取消任务，晚到响应不更新页面。
- 完整单元测试 **130 项通过**：`/private/tmp/yezi-typography-unit.xcresult`。新增字体注册与动态字号、图片页失败重试/缓存复用、取消晚响应、本地图片/远程回退回归。常规屏图片连续快滑、反向、短拖取消、末页回弹和重新打开 **1 项 UI 测试通过**：`/private/tmp/yezi-gallery-gestures.xcresult`；字体截图和文章工具栏编辑回归 **2 项通过**：`/private/tmp/yezi-typography-ui.xcresult`；375pt 小屏字体/图片/深色大字 **3 项通过**：`/private/tmp/yezi-typography-small.xcresult`。
- Release 无签名构建通过：`/private/tmp/yezi-typography-release.log`。已检查文章阅读、关于编辑、中英表情生僻字输入、图片翻页中间帧及小屏深色大字截图。以上为模拟器与离线网络夹具验证，没有真机帧率或内存曲线测量。
- [实际运行截图与原速录屏](typography-gallery-20261024/index.html)。录屏使用两张不同测试图片，仅裁去首尾非操作时间，未加速；测试数据不代表线上站点内容。本轮未上传 TestFlight/GitHub，已上传 1.0（30）不含这些调整。

## 2026-10-24 TestFlight 1.0（30）上传成功

- 01:24（Asia/Shanghai）Xcode Organizer 明确显示 `App upload complete`、`YeziApp 1.0 (30) uploaded`；归档列表状态为 `Uploaded to Apple`，Submission Status 构建号为 30。使用现有登录账号完成上传，未要求重新登录。Apple 后续处理及测试员可安装状态尚未核验。
- Release 签名归档 `/private/tmp/YeziApp-1.0-30.xcarchive`，日志 `/private/tmp/yezi-testflight-30-archive.log`；`ARCHIVE SUCCEEDED`，包内版本 1.0（30），`codesign --verify --deep --strict` 通过。
- 包含下述界面整理和会话内数据复用；测试证据见对应章节。下述「未发布」记录保留为当时状态。本次未推送 GitHub，也未部署网站。

## 2026-10-24 搜索、阅读与媒体交互整理（本地，未发布）

- 搜索打开即聚焦并显示键盘；搜索、阅读、编辑、预览和弹层期间隐藏写作按钮，关闭后结合滚动状态恢复。文章筛选与本地草稿收进右上角更多菜单。
- 多图预览从点击的图片开始，支持左右翻页、页码及重新加载；黑色预览使用深色系统工具栏，保证按钮与页码可读。音乐列表取消分割线，用紧凑留白和当前歌曲浅底区分。
- 阅读标题缩小为 26pt 并支持动态字号，日期后显示标签。关于页面复用文章的紧凑 Markdown 工具栏，保留媒体、引用和保存。删除管理的站点概览入口及无用页面，保留顶部统计；絮语标签使用文字气泡，登录页使用现有抱叶子小猫资源。
- 实际 UI 验收发现关于页退出键盘时卡顿：`updateUIView` 同步结束 UITextView 第一响应者触发 SwiftUI 更新循环。焦点切换改为主队列延后执行并核对最新状态；编辑、预览、退出及保存回归通过。
- 完整单元测试 **126 项通过**：`/private/tmp/yezi-interface-oct24-unit-final.xcresult`。常规屏 UI 回归 3 项通过、375pt 小屏及深色大字回归 2 项通过；最终音乐布局与关于页回归 1 项通过、最终搜索与多图回归 1 项通过。对应结果为 `/private/tmp/yezi-interface-oct24-{ui-fixed,small,visual-final,gallery-final}.xcresult`。
- [实际模拟器截图](interaction-20261024/index.html) 已逐项检查，使用离线示例数据，图片与封面含测试占位图；不代表线上数据或真机测试。保留上一轮会话内数据复用。本轮未推送 GitHub、上传 TestFlight 或更改版本号。

## 2026-10-24 避免页面重复加载

- 絮语、文章、评论、文件、设置、概览、作品、分类标签与引用管理在当前登录会话内复用已成功读取的数据。重新创建页面、切回已查看的筛选和打开已读文章时，无需重复请求；空列表也视为有效结果。站点信息与作者信息共享同一次设置读取。
- 同一 URL 的复用请求合并执行；离开一个页面不影响另一个读者，最后一个读者退出则取消网络请求。主动刷新会取消旧请求，并使该类数据之前的筛选、分页和详情缓存失效。保存、发布、删除、上传后清除相关数据，延迟返回的旧响应不能重新写入缓存。
- 仅使用每个 `AdminAPIClient` 独立的内存数据，最多 64 个结果、8 MiB；不写入公开缓存或磁盘。登录、退出和 401 清理数据；会话检查、备份任务、部署状态和音频播放地址不采用这套内容缓存。App 完全退出后，下一次启动正常重新加载。
- 新增 11 项请求次数与取消行为回归，覆盖页面重建、重复筛选、空数据、请求合并、手动刷新、写入失效、分页/筛选隔离、失败重试、会话隔离、退出与 401 清理。最终完整单元测试 **126 项通过**：`/private/tmp/yezi-no-repeat-load-verified.xcresult`。
- 模拟器页面导航 UI 回归 **1 项通过**：`/private/tmp/yezi-no-repeat-load-ui.xcresult`，实际走过絮语、文章、评论、管理、文件、基础信息和文章编辑。使用离线测试数据，不代表线上请求或真机能耗测量。
- 本轮尚未推送 GitHub 或上传 TestFlight，已上传的 1.0（29）不包含本轮修改。

## 2026-10-23 TestFlight 1.0（29）与 GitHub 同步

- 最终 Release 签名归档：`/private/tmp/YeziApp-1.0-29-final.xcarchive`，日志 `/private/tmp/yezi-testflight-29-final-archive.log`。包内版本为 **1.0（29）**。Xcode Organizer 使用现有账号完成上传，明确显示 `App upload complete` 和 `YeziApp 1.0 (29) uploaded`；Apple 后续处理与测试员可安装状态尚未核验。
- 包含本轮共享播放器、紧凑歌单、试听恢复、迷你播放条及此前尚未同步的原生界面、媒体编辑、AI 配图、行内评论、备份与小猫图标。以下各节「未发布」描述保留为当时记录。
- 上传前完整单元测试 **115 项通过**（`/private/tmp/yezi-build29-unit.xcresult`）；备份及行内评论的浅色/深色大字 **2 项 UI 回归通过**（`/private/tmp/yezi-build29-backup-ui.xcresult`）。播放器的常规屏、小屏与深色验证详见下节。
- 网站基于远端最新 `82cca17` 独立整合，没有用旧本地树覆盖远端。App 备份协议改用 `/api/admin/v1/native-backups`，保留网站现有备份接口与云备份流程；共享任务锁、文件锁及部署锁，归档排除恢复任务目录。网站完整测试 **380 项通过、1 项跳过**，TypeScript、定向 ESLint 及生产构建通过（`/private/tmp/yezi-web-release29-{tests-final,types-final,lint,build}.log`）。
- 网站新增接口仍需部署后生效。本轮没有在真实网站执行备份或恢复，没有部署生产网站。网站原工作目录中的既有修改保留。
- App 源码已推送 GitHub main，提交 `c3c3e0f`。网站使用 [PR #49](https://github.com/aluvien/yezi-blog/pull/49) 经过受保护分支的检查流程；CI 发现的旧依赖问题已定向修补至 Next/eslint-config-next 16.4.3、sanitize-html 2.18.1 与 follow-redirects 1.16.1，生产依赖扫描为 0 个漏洞。依赖修补后完整测试仍为 380 项通过、1 项跳过，覆盖率行 88.71%、分支 78.19%、函数 88.06%，生产构建和独立生产包 HTTP 检查通过。

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
