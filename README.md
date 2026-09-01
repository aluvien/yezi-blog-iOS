# Yezi 管理 App

Yezi 管理 App 是面向 `https://yezi.me` 的 iOS 网站管理客户端，参考 WordPress iOS 的工作台体验。登录页支持切换到 `https://yezi.biaozhu.me` 或添加自定义域名；它提供原生登录、概览/内容/评论/更多导航，并在登录后进入网站现有的安全后台，支持查看、编辑、发布和管理文章、想法、作品、评论、附件、分类、引用及站点设置。

## 打开与运行

1. 使用 Xcode 27 或更新版本打开 `YeziApp.xcodeproj`。
2. 选择 `YeziApp` scheme 和 iOS Simulator / iPhone 真机。
3. Deployment Target 为 iOS 17.0；运行前在 Xcode 的 Signing & Capabilities 中选择自己的 Team。
4. 启动后输入网站管理员密码，进入后台管理。

登录调用网站的 `/api/admin/login`，会话 Cookie 仅保存在系统网络会话与 WebKit 后台存储中；App 不保存管理员密码。退出登录会同时请求网站注销并清理本地会话。

命令行构建示例（当前开发环境的 Xcode 位于 beta 路径）：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project YeziApp.xcodeproj -scheme YeziApp \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath /private/tmp/YeziAppDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

## 架构

- `Views/RootContentView.swift`：原生管理壳、登录页、四个管理入口、会话生命周期和 WebKit 后台容器。
- `App/YeziAppApp.swift`：App 入口。
- 文章 Markdown 编辑器、附件上传、引用卡片、评论审核、站点设置等编辑流程复用网站后台已有实现，避免移动端与网站出现两套不一致的管理逻辑。
- WebKit 使用默认数据存储承接登录会话；外部链接交给系统打开，后台内链保留在 App 内导航。

## 管理页面

登录后通过原生底部导航进入：

- 概览：后台仪表盘、文章/想法/作品/评论统计。
- 内容：文章列表、新建/编辑文章、草稿与发布。
- 评论：审核、公开/撤回、作者回复和删除。
- 更多：想法、作品、关于我、引用库、附件、分类与标签、常规设置、音乐设置和外观主题。

这些页面加载网站已有的 `/admin/...` 路由，因此现有的 Markdown 工具、图片上传、引用快照和服务器端校验均保持一致。

## 验证

已使用 Xcode 27 的 Debug Simulator 配置构建成功：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project YeziApp.xcodeproj -scheme YeziApp \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath /private/tmp/YeziAppAdminDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

当前执行环境的 CoreSimulator 服务无法启动，因此未能在本机自动完成交互式登录验证；在 Xcode 中运行后，使用网站管理员密码登录即可验证完整后台流程。
