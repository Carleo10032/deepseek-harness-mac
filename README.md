# DeepSeek Harness Mac

一个最小的 SwiftUI macOS 外壳：启动 `npx @deepseek-ai/dsh@0.1.0-rc.6 web`，并在
`WKWebView` 中显示本地 Web UI。点击红色关闭按钮时隐藏窗口并保持后台服务；
点击 Dock 图标可重新显示，使用 `Command-Q` 才会完全退出。

A minimal SwiftUI macOS shell that boots the [DeepSeek Harness](https://github.com/deepseek-ai/DeepSeek-Harness)
local Web UI inside a `WKWebView`, with Dock-friendly hide/restore behavior.

> [!IMPORTANT]
> **免责声明 / Disclaimer**
> 本项目是社区开发的非官方封装，与 DeepSeek（深度求索）**没有任何关联**，也
> 未获得其认可或背书。"DeepSeek" 名称与鲸鱼 Logo 是 DeepSeek 的商标，归其
> 所有。本项目仅以技术兼容为目的引用该名称与图标。
>
> This is an unofficial community wrapper. It is **not affiliated with,
> endorsed by, or sponsored by DeepSeek**. The "DeepSeek" name and the whale
> logo are trademarks of DeepSeek. They are used here solely for technical
> compatibility.

## 功能

- 一键启动：优先复用 npm 已下载的 `dsh` 缓存，避免每次启动都等待 `npx`
  重新解析依赖；缓存不存在时才回退到 `npx`。
- 本地服务发现：从子进程输出中解析 `http://127.0.0.1:<port>`，服务就绪后
  自动加载页面。
- Dock 友好：点红色关闭按钮只是隐藏窗口、服务继续在后台运行；点 Dock 图标
  重新显示窗口；`Command-Q` 完全退出并清理子进程树。
- 原生下载：网页下载由 `WKDownloadDelegate` 接管，Session Log 和其他文件会
  弹出 macOS 保存面板，并支持由前端生成的 `blob:` 下载。网页原有的"下载已
  开始"提示不会提前出现；用户取消时保持静默，只有文件确实保存完成后才显示
  下载成功。
- 图标：使用 DeepSeek Harness 官方 Web UI 包中的黑色鲸鱼 `favicon.svg`，
  保持原始路径轮廓与黑色填充，仅增加 macOS 图标所需的白色圆角底板与留白
  （生成脚本见 [`Scripts/make_icon.swift`](Scripts/make_icon.swift)）。

## 前置要求

- macOS 13.0 或更高版本
- Xcode Command Line Tools（提供 `swiftc`，仅构建时需要）
- Node.js 与 `npx`（运行 App 时需要；`npx` 位于 PATH 中，或已通过
  `npx @deepseek-ai/dsh@0.1.0-rc.6` 下载过缓存）

## 构建

```bash
chmod +x build.sh
./build.sh
```

生成文件：`build/DeepSeek Harness.app`（临时 ad-hoc 签名；如需分发请改用
你自己的开发者证书签名并公证）。

## 工作原理

App 启动后按以下顺序寻找 DeepSeek Harness 的可执行入口：

1. PATH 中的全局 `dsh`（`/opt/homebrew/bin/dsh`、`/usr/local/bin/dsh` 等）
2. `~/.npm/_npx` 缓存中与 `0.1.0-rc.6` 版本匹配的 `dsh`
3. 回退到 `npx --yes @deepseek-ai/dsh@0.1.0-rc.6`

随后以 `web --host 127.0.0.1 --port 0` 启动本地服务（随机端口，仅监听回环
地址），从标准输出中解析实际端口，并在 `WKWebView` 中加载。

## 许可证

[MIT](LICENSE) © 2026 Carleo10032

本项目基于 [DeepSeek Harness](https://github.com/deepseek-ai/DeepSeek-Harness)
（MIT License, © DeepSeek）构建。App 图标衍生自其 Web UI 包中的
`favicon.svg`，DeepSeek 名称与鲸鱼 Logo 的商标权归 DeepSeek 所有。
