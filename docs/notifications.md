# iOS 通知

## 发布状态（2026-10-24）

App 已于 19:14（上海时间）成功上传 TestFlight **1.0（34）**，Xcode 显示 Uploaded to Apple，分发签名确认生产推送权限。iOS 单元测试 148 项及关键 UI 回归 6 项通过。配套网站通知代码通过 PR #50 同步；服务器部署、真实设备注册及 Apple 推送送达仍需联调。下文“本地”“尚未上传”等内容是此前开发记录，以本节状态为准。

入口：管理 → 通知。用户主动开启后申请系统权限，分别选择新评论与 QQ 音乐登录失效提醒，可发送测试通知。网站通过 APNs 发送，App 没有新增后台轮询或定时刷新任务。

## App

- `YeziApp/App/PushNotifications.swift`：系统通知代理、权限状态、站点隔离、设备令牌与偏好同步、通知设置 UI。
- `YeziApp/YeziApp.entitlements`：Debug 使用 development，Release / TestFlight 使用 production。Bundle ID 为 `me.aluvien.yeziblog`，开发团队为 `DR2TNGTRAJ`。
- 点击评论通知后用私有接口读取确切评论，打开回复页；点击 QQ 音乐失效通知打开音乐设置。登录后才处理路由，不自动切换到通知指定的其他站点。
- 登出或切换站点先注销设备；服务端同时核对登录会话有效期和改密撤销代次。通知权限被关闭后，下次回到 App 撤销绑定。设备 token 只通过已登录 HTTPS 管理接口提交。

## 配套网站源码位置

通知最初在从最新 `origin/main` 创建的独立 worktree 开发；用户确认使用本地 `yezi-blog` 后，已合入原网站目录并保留其中已有改动：

- 当前网站目录：`/Users/aluvien/Develop/Website/yezi-blog`
- 独立开发 worktree：`/private/tmp/yezi-web-ios-notifications`，分支 `codex/ios-push-notifications`，基于 `96d8cee`。
- 完整服务端说明：当前网站目录的 `docs/ios-push-notifications.md`。
- 本地旧版 QQ 健康检查兼容其 `updatedAt` 会话版本；检查期间切换登录会话时不发送旧检测结果的提醒。
- 数据迁移 schema 18，新增 `/api/admin/v1/push-devices`、`/push-devices/test`，以及单条评论 GET 接口。
- 环境变量：`APNS_KEY_ID`、`APNS_TEAM_ID`、`APNS_KEY_PATH`（或 secret `APNS_PRIVATE_KEY`）、`APNS_SITE_URL`。密钥只在服务器，禁止进 App、Git、公开 API 或日志。

用户已提供并确认 APNs 密钥。本地私有 `.env.local` 已配置密钥文件引用、Key ID、站点地址，权限为 0600，且由 Git 忽略；密钥没有复制到源码或 App。文件已从 iCloud 下载，P-256 格式与本地 ES256 签名/验签通过。Team ID 暂沿用 App 的开发团队，尚未通过 Apple 服务验证密钥的团队、授权范围及撤销状态。尚未部署网站、签名上传新 App 或完成真机推送。

## 验证（2026-10-24）

- 合入原网站目录后：类型检查、全部 255 项测试、生产构建通过。临时启动生产构建后，通知状态接口在认证下返回 HTTP 200 / `configured=true`，未认证返回 401，三个通知数据表迁移成功。启动验证使用独立临时数据库并已停止进程，未注册真实设备或发送通知；日志为 `/private/tmp/yezi-local-push-runtime.log`。原站数据库未用于此启动验证。
- 网站完整测试 391 通过、1 跳过，包含新增通知测试 11 项；最终通知测试 11 项再次通过；TypeScript、改动文件 ESLint、生产构建通过。
- App 单元测试 148 项通过：`/private/tmp/yezi-push-unit-final.xcresult`。
- App 通知界面测试 3 项通过：`/private/tmp/yezi-push-ui-final.xcresult`，包含设置页、评论回复、音乐设置跳转。预览模式不申请真实通知权限，也不发送 APNs。
- 模拟器 Debug 与未签名真机 Release 编译通过。尚未验证 Apple 签名描述文件实际开启 Push、真实设备 token、APNs 接受与系统后台/冷启动点击通知。
- [通知设置实际运行截图](design/notifications-20261024/settings.png)。
