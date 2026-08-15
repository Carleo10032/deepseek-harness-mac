<div align="center">

<img src="Assets/AppIcon-preview.png" alt="DeepSeek Harness Mac 应用图标" width="112" />

# DeepSeek Harness Mac

**[DeepSeek Harness](https://github.com/deepseek-ai/DeepSeek-Harness) 本地 Web UI 的非官方 SwiftUI macOS 外壳。**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)
![Last commit](https://img.shields.io/github/last-commit/Carleo10032/deepseek-harness-mac)

[English](README.md) · [中文](README.zh.md)

</div>

> [!IMPORTANT]
> **免责声明** — 本项目是社区开发的非官方封装，与 DeepSeek（深度求索）**没有任何
> 关联**，亦未获得其认可或背书。"DeepSeek" 名称与鲸鱼 Logo 是 DeepSeek 的商标，归其
> 所有；本项目仅以技术兼容为目的引用该名称与图标。
>
> **Disclaimer** — This is an unofficial community project. It is **not affiliated with,
> endorsed by, or sponsored by DeepSeek**. The name "DeepSeek" and the whale logo are
> trademarks of DeepSeek and remain its property.

<p align="center">
  <img src="Assets/AppScreenshot.png" alt="DeepSeek Harness Mac 在 macOS 上运行" width="100%" />
</p>

## 概览

DeepSeek Harness Mac 以本地服务的方式启动 DeepSeek Harness CLI（`dsh web`），并把它的
Web UI 显示在原生 `WKWebView` 窗口中。

## 功能

- **启动快** — 优先复用 `npx` 已缓存的 `dsh`，后续启动跳过依赖解析；缓存不存在时才
  回退到 `npx`。
- **原生下载** — 网页下载由 `WKDownloadDelegate` 接管：Session Log 和其他文件会弹出
  macOS 保存面板（包括前端生成的 `blob:` 下载）。网页原有的"下载已开始"提示被抑制；
  用户取消时保持静默，只有文件真正保存完成后才显示确认。
- **Dock 友好** — 红色关闭按钮只隐藏窗口、服务继续运行；点击 Dock 图标恢复窗口；
  `⌘Q` 完全退出并终止整个子进程树。
- **全屏体验优化** — 在全屏模式下关闭窗口时不会残留黑屏；App 位于独立的全屏空间时，
  点击一次 Dock 图标即可直接切回，无需重复点击。
- **严格固定端口** — 启动前先探测首选端口：已有正在运行的 DeepSeek Harness 则直接
  连接而不启动第二个实例；被其他程序占用时明确提示冲突，不再静默漂移到随机端口。
- **外部链接交给系统浏览器** — 指向其他网站的链接（包括 `target="_blank"` 和
  `window.open`）会在你的默认浏览器中打开，不会抢占 App 窗口；`mailto:` 链接交给邮件
  客户端。
- **原生对话框** — 网页调用 `alert`、`confirm`、`prompt` 时会显示 macOS 原生对话框。
- **可靠的启动界面** — 服务启动时显示进度，拿到本地 URL 后立即加载 Web UI；启动失败
  时显示错误状态和"重新启动"按钮。
- **官方图标** — 应用图标衍生自 DeepSeek Harness Web UI 包中的官方黑色鲸鱼
  `favicon.svg`，保留原始路径轮廓与黑色填充，置于 macOS 白色圆角底板上
  （生成脚本：[`Scripts/make_icon.swift`](Scripts/make_icon.swift)）。

## 环境要求

| 依赖 | 版本 | 用途 | 安装方式 |
| --- | --- | --- | --- |
| macOS | 13.0+ | 运行 | — |
| Xcode Command Line Tools | 任意较新版本 | 构建 | `xcode-select --install` |
| Node.js（含 `npx`） | 建议 20+（LTS） | 运行 | `brew install node`、[nvm](https://github.com/nvm-sh/nvm) 或 [Volta](https://volta.sh) |

## 安装

### 从源码构建

```bash
# 1. 克隆仓库
git clone https://github.com/Carleo10032/deepseek-harness-mac.git
cd deepseek-harness-mac

# 2. 如果缺少 swiftc，先安装 Xcode Command Line Tools
xcode-select --install

# 3. 构建 App
chmod +x build.sh
./build.sh
```

构建产物位于 `build/DeepSeek Harness.app`。

### 安装到"应用程序"文件夹

```bash
cp -R "build/DeepSeek Harness.app" /Applications/
open "/Applications/DeepSeek Harness.app"
```

> **关于 Gatekeeper：** `build.sh` 使用临时（ad-hoc）签名，本地构建的副本可直接运行。
> 如果从网上下载的副本被 Gatekeeper 拦截，请移除其隔离属性——仅限你信任的副本：
>
> ```bash
> xattr -dr com.apple.quarantine "/Applications/DeepSeek Harness.app"
> ```

## 使用

- 启动 App，本地服务就绪后会自动加载 Web UI。
- Harness 会话的工作目录：若 `~/Documents/Vibe` 存在则使用它，否则使用你的主目录
  （见 [`Sources/HarnessService.swift`](Sources/HarnessService.swift) 中的 `defaultWorkingDirectory()`）。
- 点击红色关闭按钮隐藏窗口，服务继续运行；点击 Dock 图标恢复窗口。
- 按 `⌘Q` 完全退出 App 并关闭本地服务。
- 启动失败时，窗口会显示最后一行日志、"重新启动"按钮，以及一个
  **"安装全局 dsh"** 按钮——它会执行 `npm install --global @deepseek-ai/dsh`，成功后
  自动重新启动。

## 配置

以下启动期设置从 `UserDefaults` 读取（用 `defaults write` 写入，域名是
`io.github.carleo10032.deepseek-harness-mac`）：

| 键 | 默认值 | 含义 |
| --- | --- | --- |
| `DSHPreferredPort` | `3080` | 首选本地端口；设为 `0` 表示"每次都用随机空闲端口"，其他值严格生效——端口被占用时明确提示冲突，不再静默换端口。 |
| `DSHBinOverride` | *(空)* | 指向某个 `dsh` 可执行文件的绝对路径，优先级高于所有自动发现来源。 |
| `DSHPinnedVersion` | `0.1.0-rc.6` | 用于 npx 缓存查找、`npx` 兜底和全局安装的 `dsh` 版本；设为 `latest` 则始终使用最新版本。 |

```bash
# 改用其他固定端口
defaults write io.github.carleo10032.deepseek-harness-mac DSHPreferredPort -int 8080

# 固定使用自定义 dsh 构建
defaults write io.github.carleo10032.deepseek-harness-mac DSHBinOverride -string "/path/to/dsh"

# 始终跟随最新 dsh 版本，而不是固定版本
defaults write io.github.carleo10032.deepseek-harness-mac DSHPinnedVersion -string "latest"
```

## 工作原理

1. 启动时，App 按以下顺序寻找 DeepSeek Harness 可执行文件：
   1. `DSHBinOverride` 指定的路径（若设置且可执行）；
   2. `PATH` 中的全局 `dsh`（Homebrew、Volta、`~/.local/bin`、`~/.npm-global/bin` 等）；
   3. `~/.npm/_npx` 缓存中版本匹配所配置版本的 `dsh`；
   4. 兜底：`npx --yes @deepseek-ai/dsh@<版本>`（设为 `latest` 时用 `@deepseek-ai/dsh`）。
2. 启动前先探测 `127.0.0.1:<DSHPreferredPort>` 上是否已有正在运行的 DeepSeek Harness
   （通过其 `/manifest.webmanifest` 识别）：已有则直接连接，不再启动第二个实例；若是
   其他程序占用，则明确提示端口冲突，而不再静默换端口。然后以
   `web --host 127.0.0.1 --port <DSHPreferredPort>` 启动本地服务——仅监听回环地址。
3. 从子进程输出中解析出 `http://127.0.0.1:<port>` 地址，并在 `WKWebView` 中加载。

Harness 版本默认是 `0.1.0-rc.6`，由 `DSHPinnedVersion` 设置控制（见"配置"一节）；
设为 `latest` 可始终跟随最新版本。

## 常见问题

| 现象 | 可能原因 | 解决办法 |
| --- | --- | --- |
| 提示"找不到 dsh，也未找到 npx" | 未找到 `dsh` 或 Node.js/`npx` | 安装 Node.js，或点击"安装全局 dsh" |
| 首次启动较慢 | `npx` 缓存未命中 | 属正常现象；后续启动会复用缓存的 `dsh` |
| 窗口显示启动失败 | 本地服务退出 | 查看窗口中显示的最后一行日志，确认固定版本的 `dsh` 可达 |
| macOS 拦截下载的副本（"已损坏"） | Gatekeeper + 临时签名 | `xattr -dr com.apple.quarantine`（见"安装"一节） |

## 参与贡献

欢迎提交 Bug 报告和 Pull Request。请 Fork 本仓库，使用 `./build.sh` 构建，并保持改动
小而聚焦。问题请提交到
[Issue 追踪器](https://github.com/Carleo10032/deepseek-harness-mac/issues)。

## 许可证

[MIT](LICENSE) © 2026 Carleo10032

基于 [DeepSeek Harness](https://github.com/deepseek-ai/DeepSeek-Harness)（MIT ©
DeepSeek）构建。应用图标衍生自其 Web UI 包中的 `favicon.svg`；"DeepSeek" 名称与鲸鱼
Logo 的商标归 DeepSeek 所有。
