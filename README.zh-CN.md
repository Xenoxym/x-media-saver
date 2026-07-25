# X Media Saver

[English](README.md) | **简体中文**

X Media Saver 是一个供个人侧载使用的 iOS 16+ SwiftUI App。当前版本保留单链接视频/动图下载，同时新增一个类似浏览器扩展的工作流：你在 App 内的 X 网页正常登录、打开书签并滚动，App 只解析这个网页会话已经加载的书签响应，然后在本机筛选、下载并保存媒体到照片图库。

本项目没有自建后端、代理或第三方下载 API；也不使用 X OAuth、开发者 API key 或用户 Bearer Token。

## 当前功能

- 单链接下载：粘贴 `x.com` / `twitter.com` 帖子地址，选择 MP4 质量并保存视频或动图。
- 内置 X 浏览器：登录由 `WKWebView` 中的 X 官方网页完成。
- 书签捕获：打开 X 书签页面后手动浏览，或让 App 自动向下滚动并收集页面自己返回的书签数据。
- 批量筛选：可分别选择图片、动图和视频。
- 时间筛选：按帖子的发布时间选择起止日期。
- 会话统计：显示当前已捕获的书签、含媒体帖子、图片、动图与视频数量。
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
- 只接受 X/Twitter 域名的相关响应，并阻止内置浏览器顶层跳转到其他域名；
- 不把捕获内容发送到任何自建服务。

“退出 X”会删除内置浏览器中与 `x.com` / `twitter.com` 相关的网站数据，不影响 Safari。

## 使用书签批量保存

1. 打开 **X 浏览器** 标签。
2. 在 X 网页里正常登录。
3. 点击顶部 **书签**。
4. 手动向下浏览，或点击底部 **自动滚动抓取**。看到数量长期不再增长后可停止。
5. 切换到 **书签** 标签。
6. 选择图片、动图、视频和可选日期范围。
7. 点击 **批量下载并保存到照片**。
8. 首次保存时，允许 App 使用照片图库的“仅添加”权限。

统计和下载范围只包括当前浏览器已经实际加载到本机的条目。App 不会在后台偷偷拉取未滚动到的页面。

## 技术限制

这个实现遵守登录会话的可见范围，但依赖 X 网页内部响应格式，因此有以下重要限制：

- X 没有为第三方 iOS App 提供稳定、文档化的“复用网页会话书签 JSON”接口。GraphQL operation 名称、字段层级或网页实现改变时，捕获可能失效，需要更新 App。
- App 不会绕过删除、停用、地区限制、年龄限制、受保护账号权限或其他 X 访问控制。能否捕获取决于该账号在内置浏览器中正常浏览时实际得到什么。
- 登录挑战、验证码和账号风控完全由 X 决定。App 不自动填写、破解或转移这些流程。
- 时间筛选使用帖子 `created_at`，不是“加入书签时间”；X 当前网页书签响应没有可靠提供后者。
- “书签总数”是已加载数量，不是服务端保证的全量计数。若自动滚动过早停止，可返回浏览器继续滚动。
- 同一媒体出现在多个已捕获帖子时，会按 `media_key` 去重后批量保存。
- 当前只保存 X 提供的直接图片和 MP4 变体；HLS 播放列表、直播、外部卡片播放器不做拼接或转码。
- 下载使用前台 `URLSession`，大量内容时请保持 App 在前台。
- 网页会话可能因 X 的安全策略、系统清理或侧载 App 重签而失效，需要重新登录。
- 保存媒体不代表获得转载或再利用权利；使用者仍需遵守适用法律、版权和 X 条款。

## 单链接模式

单链接页面先查找当前内置浏览器会话中已经捕获的同一帖子。若没有捕获记录，则保留旧版的快捷解析路径，直接请求 X 的公开 syndication/embed 响应。该公开响应不是稳定的官方开发者 API，因此可能无法解析登录后可见的帖子。

对于登录后才能看到的帖子，先在 **X 浏览器** 中打开它，使页面正常加载，再返回单链接页面重试。单链接模式当前保存视频和动图；图片批量保存从书签页完成。

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
