# X Media Saver

[English](README.md) | **简体中文**

X Media Saver 是一个供个人侧载使用的 iOS 16+ SwiftUI App。当前版本保留单链接视频/动图下载，同时新增持久的浏览器登录会话：首次在 App 内登录 X 后，单链接和书签同步都可以从原生界面自动驱动同一个 WebView 加载数据。

本项目没有自建后端、代理或第三方下载 API；也不使用 X OAuth、开发者 API key 或用户 Bearer Token。

## 当前功能

- 单链接下载：粘贴 `x.com` / `twitter.com` 帖子地址，选择 MP4 质量并保存视频或动图。
- 内置 X 浏览器：登录由 `WKWebView` 中的 X 官方网页完成。
- 快速增量书签同步：登录后打开“X 浏览器”即开始约每秒一次的滚动，同时捕获全部书签响应；已有 Post ID 原位更新，新 ID 才追加，本地记录不会因 X 端删除而自动移除。
- 本地 Post 索引：以 post 为最小单位保存作者、正文、发布时间和媒体元数据，重启 App 后仍保留；媒体文件只在点击保存时下载。
- 分类与搜索：支持按账号或 Hashtag 分组；可搜索 @用户名、显示昵称、数字 User ID、正文和 Hashtag，并按账号帖子数或名称排序。
- 原生 Post 详情：点击列表即可查看完整正文、原图和最高质量 MP4 预览。
- 时长与大小筛选：按预设视频/动图时长和一个 Post 的媒体总大小筛选。
- Files 流式导出：逐个写入可见的 Images、Animated GIFs、Videos 文件夹，并生成逐行 `posts.jsonl`；不使用 ZIP，也不把整个批次放进内存。
- 跨重启防重复：照片保存和 Files 导出分别记录成功的 `media_key`，默认跳过已完成媒体。
- 存储管理：显示受控存储分类，可清理临时、URLSession 和 X WebKit 缓存，同时保留 X 登录 Cookie。
- 批量筛选：可分别选择图片、动图和视频。
- 时间筛选：按帖子的发布时间选择起止日期。
- 本地索引统计：显示已索引书签、含媒体帖子、图片、动图与视频数量。
- 本机保存：直接从 X 的 `pbs.twimg.com` / `video.twimg.com` 媒体地址下载，并以“仅添加”权限写入照片图库。
- 逐项进度、取消、失败/跳过数量汇总。

X 的[媒体文档](https://docs.x.com/x-api/media/introduction)把对象区分为 photo、video 和 animated GIF；其 `extended_entities` 数据也使用 `photo`、`video`、`animated_gif` 类型。本 App 按这些类型单独统计，其中动图选择其最高质量 MP4 变体并保存为视频资产。

## 登录与隐私边界

这个版本明确禁止 OAuth，也没有实现任何开发者 API 登录。X 官方书签 API 本身要求用户访问令牌和 OAuth；该路线仅作为为什么本项目不使用官方 API 的技术背景，不会被 App 调用，参见 [X Bookmarks 文档](https://docs.x.com/x-api/posts/bookmarks/introduction)。

登录页面直接来自 `https://x.com`。账号、密码、验证码和二次验证只输入到 X 网页里，并由 WebKit 的持久网站数据存储维护登录会话。Apple 对[默认 WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)的说明确认它会把网站数据持久保存到磁盘；本 App 只让 WebKit 使用该存储，并提供按 X 域名清除的退出操作。原生代码：

- 不读取密码输入框；
- 不查询、复制、导出或上传 Cookie；
- 不收集授权 Header 或令牌；
- 不代表网页构造额外的 X GraphQL/API 请求；
- 只在文档加载开始时注入一个很小的观察脚本，复制网页自身 `fetch` / XHR 已收到的 `Bookmarks`、`BookmarkFolderTimeline` 和 `TweetDetail` JSON 响应给本机解析器；
- 只捕获 X/Twitter 域名的相关响应；浏览器仅允许 HTTPS 等安全导航，以兼容 X 登录、验证和跳转流程；
- 不把捕获内容发送到任何自建服务。
- 捕获后的 post 与媒体元数据只保存在本 App 受系统数据保护的 Application Support 目录；不会预先下载媒体文件。

“退出 X”会删除内置浏览器中与 `x.com` / `twitter.com` 相关的网站数据，不影响 Safari。

## 使用书签批量保存

1. 首次使用时打开 **X 浏览器**，在 X 网页里正常登录。
2. App 默认加载 `x.com/home`；登录有效时自动打开书签并快速增量同步，失效时由 X 自己跳转登录。
3. 在书签页按账号、帖子或 Hashtag 浏览，并按账号、正文、Hashtag、发布时间、时长和大小组合筛选。
4. 选择图片、动图、视频和可选日期范围。
5. 点击 **批量下载并保存到照片**。
6. 首次保存时，允许 App 使用照片图库的“仅添加”权限。

统计和下载范围只包括自动同步过程中 X 网页实际加载到本机的条目。

同步采用只追加/更新逻辑：已存在的 Post ID 不会重复增加，新 ID 才计为新增，X 端删除不会自动删除本地条目。照片保存也默认跳过此版本已经记录为成功的 `media_key`。旧版本没有保存台账，因此界面提供“将当前筛选标记为已保存（不下载）”用于迁移已有照片。

## Files 流式资料库

默认位置为 **我的 iPhone > X Media Saver > Library**，也可通过系统文件夹选择器选取 iCloud Drive 或其他 Files 目录：

```text
Library/
├── Images/
├── Animated GIFs/
├── Videos/
├── posts.jsonl
└── export-state.jsonl
```

App 每次只下载一个媒体临时文件，移动到类型文件夹并记录状态后才处理下一个。`posts.jsonl` 保存 Post 正文、账号、日期以及本地相对媒体路径，用于离线复现已捕获内容；`export-state.jsonl` 采用追加记录，重复或中断后继续导出时会跳过已完成的 `media_key`。

## 技术限制

这个实现遵守登录会话的可见范围，但依赖 X 网页内部响应格式，因此有以下重要限制：

- X 没有为第三方 iOS App 提供稳定、文档化的“复用网页会话书签 JSON”接口。GraphQL operation 名称、字段层级或网页实现改变时，捕获可能失效，需要更新 App。
- App 不会绕过删除、停用、地区限制、年龄限制、受保护账号权限或其他 X 访问控制。能否捕获取决于该账号在内置浏览器中正常浏览时实际得到什么。
- 登录挑战、验证码和账号风控完全由 X 决定。App 不自动填写、破解或转移这些流程。
- 时间筛选使用帖子 `created_at`，不是“加入书签时间”；X 当前网页书签响应没有可靠提供后者。
- “书签总数”是本机持久保留的已加载数量，不是服务端保证的全量计数。若自动同步过早停止，可以再次点击同步。
- 自动同步捕获的是网络响应而不是屏幕 cell 数；快速滚动不会主动跳过 cursor 页，但未公开文档的网页流程仍无法提供服务端全量保证。
- 切到本 App 的其他栏目时同步仍可继续；锁屏或切换到其他 App 后，iOS 可能暂停 WebKit，因此它不是不受限制的系统后台任务。
- X 书签 JSON 通常提供时长但不提供文件字节数。App 通过低并发、低优先级的 HEAD/Range 队列探测直接 CDN 地址；无法确认的项目明确显示“大小未知”。
- 存储管理可删除 WebKit 磁盘/内存/Fetch 缓存而保留 Cookie。Cookie 和浏览器数据库按设计留在私有沙盒，绝不会导出到 Files。
- 同一媒体出现在多个已捕获帖子时，会按 `media_key` 去重后批量保存。
- 当前只保存 X 提供的直接图片和 MP4 变体；HLS 播放列表、直播、外部卡片播放器不做拼接或转码。
- 下载使用前台 `URLSession`，大量内容时请保持 App 在前台。
- 网页会话可能因 X 的安全策略、系统清理或侧载 App 重签而失效，需要重新登录。
- 保存媒体不代表获得转载或再利用权利；使用者仍需遵守适用法律、版权和 X 条款。

## 单链接模式

单链接页面先查找当前内置浏览器会话中已经捕获的同一帖子；若没有，它会自动让持久 WebView 使用现有 X 登录 Cookie 打开该链接并等待 `TweetDetail` 响应。若浏览器会话仍无法解析，则回退到旧版的公开 syndication/embed 响应。

对于登录后才能看到且当前账号有权访问的帖子，不再需要先手动打开。登录有效期内直接粘贴链接即可。单链接模式当前保存视频和动图；图片批量保存从书签页完成。

## 在 Xcode 中构建

要求：macOS、建议 Xcode 16 或更新版本，以及 iOS/iPadOS 16+ 设备。

1. 打开 `XMediaSaver.xcodeproj`。
2. 选择 **XMediaSaver** target。
3. 在 **Signing & Capabilities** 中选择你的 Apple Development Team。
4. 把 `com.example.XMediaSaver` 改为你自己的唯一 Bundle Identifier。
5. 选择已连接的 iPhone/iPad，然后运行。
6. 可通过 **Product > Test** 运行单元测试。

## 生成 IPA

### Xcode Archive

1. 选择 **Any iOS Device (arm64)** 或已连接设备。
2. 执行 **Product > Archive**。
3. 在 Organizer 中选择本地 Development 分发并导出 `.ipa`。

### 本机生成未签名 IPA

在项目目录运行：

```bash
bash Scripts/package-unsigned-ipa.sh
```

输出为 `artifacts/XMediaSaver-unsigned.ipa`。它不能直接安装，必须由 SideStore 或 Sideloadly 在本地签名。

### GitHub Actions

`.github/workflows/build-unsigned-ipa.yml` 会在 GitHub 托管的 macOS runner 上：

1. 使用关闭代码签名的 Release 配置构建设备 `.app`；
2. 验证 Mach-O 和标准 `Payload/` 结构；
3. 生成未签名 IPA、校验和及构建日志；
4. 上传工作流 artifacts。

在仓库 **Actions > Build unsigned IPA > Run workflow** 手动运行，或向 `main` 推送相关工程修改。
完成后下载名为 `XMediaSaver-unsigned-ipa` 的 artifact。

不要把 Apple ID、密码、证书、Provisioning Profile、API key 或其他 Apple 凭证放入 GitHub Secrets 或仓库文件。GitHub 只编译未签名 App；下载 artifact 后使用 SideStore/Sideloadly 在自己的设备上本地签名。

## 安装

- SideStore：按照 [SideStore 官方安装文档](https://docs.sidestore.io/docs/installation/install)配置，然后从 Files 选择 IPA。
- Sideloadly：从 [sideloadly.io](https://sideloadly.io/) 获取客户端，把 IPA 拖入并只在本机完成 Apple 账号签名。

## 工程结构

```text
XMediaSaver/
├── .github/workflows/build-unsigned-ipa.yml
├── XMediaSaver.xcodeproj
├── XMediaSaver/
│   ├── Models/
│   ├── Services/
│   ├── ViewModels/
│   ├── Views/
│   ├── Resources/Assets.xcassets/
│   └── Info.plist
├── XMediaSaverTests/
└── Scripts/
```

核心只依赖 Apple frameworks：SwiftUI、Foundation/URLSession、WebKit、UIKit 和 Photos。

## License

MIT。见 `LICENSE`。
