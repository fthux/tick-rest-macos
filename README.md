<div align="center">
<p align="center">
  <img src="brand-assets/app-name-light.svg#gh-light-mode-only" alt="Tick Rest" width="442" height="100" align="middle"><img src="brand-assets/app-name-dark.svg#gh-dark-mode-only" alt="Tick Rest" width="442" height="100" align="middle"><img src="Sources/TickRestCore/Resources/AppIcon.png" alt="Tick Rest app logo" width="100" height="100" align="middle">
</p>

[![GitHub top language](https://img.shields.io/github/languages/top/fthux/tick-rest-macos?logo=github)](https://github.com/fthux/tick-rest-macos/commits/master/)
[![GitHub License](https://img.shields.io/github/license/fthux/tick-rest-macos?logo=github)](LICENSE)
[![Security](https://sonarcloud.io/api/project_badges/measure?project=fthux_tick-rest-macos&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=fthux_tick-rest-macos)

[![Reliability](https://sonarcloud.io/api/project_badges/measure?project=fthux_tick-rest-macos&metric=reliability_rating)](https://sonarcloud.io/summary/new_code?id=fthux_tick-rest-macos)
[![Maintainability](https://sonarcloud.io/api/project_badges/measure?project=fthux_tick-rest-macos&metric=sqale_rating)](https://sonarcloud.io/summary/new_code?id=fthux_tick-rest-macos)
<!-- [![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=fthux_tick-rest-macos&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=fthux_tick-rest-macos) -->

[![Code Smells](https://sonarcloud.io/api/project_badges/measure?project=fthux_tick-rest-macos&metric=code_smells)](https://sonarcloud.io/summary/new_code?id=fthux_tick-rest-macos)
[![Vulnerabilities](https://sonarcloud.io/api/project_badges/measure?project=fthux_tick-rest-macos&metric=vulnerabilities)](https://sonarcloud.io/summary/new_code?id=fthux_tick-rest-macos)
[![Ask DeepWiki](brand-assets/deepwiki-badge.svg)](https://deepwiki.com/fthux/tick-rest-macos)
</div>

<p align="center">
  <b>Yet another break time reminder app.</b><br />
  Take regular breaks from your computer to rest your eyes, relax, and move around.
</p>

<p align="center">
  <strong>原生 macOS 体验 · 轻巧体积 · 高效运行</strong><br />
  常驻菜单栏的休息提醒工具，把资源留给工作，把休息交给 Tick Rest。
</p>

<p align="center">
  <img src="screenshots/fullscreen-wallpaper.png" alt="Tick Rest 壁纸背景全屏休息提醒" width="900">
</p>

## 为什么选择 Tick Rest？

- **为 Mac 原生打造** — 使用 Swift、SwiftUI 和 AppKit，融入 macOS 的菜单栏、窗口与系统外观。
- **轻巧的安装体积** — 无需捆绑浏览器引擎或额外运行时，让下载和安装保持轻便。
- **面向常驻的高效设计** — 原生编译与渲染，减少额外开销，适合全天留在菜单栏。
- **按你的节奏休息** — 内置护眼、50/10、番茄工作法等方案，支持自定义间隔、时长和延后规则。
- **灵活的提醒方式** — 支持小窗与全屏提醒；全屏模式可选择纯色、渐变或图片背景，适配多显示器。
- **配合工作状态** — 可设置工作时段、离席检测和全屏暂缓提醒，随时从菜单栏暂停或立即休息。
- **注重隐私** — 无需账号、没有广告，设置与休息记录保存在本机。
- **熟悉的使用体验** — 支持浅色／深色外观，以及简体中文、繁体中文、英语、日语和韩语。

## 安装

**Homebrew（推荐）：**

```bash
brew install --cask fthux/tap/tickrest
```

**手动安装：**

从 [Releases](https://github.com/fthux/tick-rest-macos/releases) 下载 ZIP 安装包，解压后将应用拖入「应用程序」文件夹。Apple Silicon 选择 `arm64`，Intel 选择 `x86_64`，也可选择兼容两者的 `universal`。

首次打开时，macOS **Gatekeeper** 可能提示无法验证开发者并阻止启动。确认应用来自本项目后，前往「系统设置 → 隐私与安全性」，点击「仍要打开」并确认。详见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

## 快速开始

1. 打开 Tick Rest，在首次引导中选择休息方案。
2. 在设置中选择小窗或全屏提醒，按需调整时间与外观。
3. 关闭设置窗口，让 Tick Rest 在菜单栏中继续提醒。

默认每工作 **20 分钟休息 20 秒**，累计工作 **60 分钟活动 5 分钟**。

## 界面预览

点击截图可查看原图。

### 小窗提醒

标准、小号、迷你三种尺寸，也可折叠以减少遮挡。

<table>
  <tr>
    <th>标准</th>
    <th>小号</th>
    <th>迷你</th>
  </tr>
  <tr>
    <td align="center" valign="middle"><a href="screenshots/reminder-card-normal.png"><img src="screenshots/reminder-card-normal.png" alt="标准" width="315"></a></td>
    <td align="center" valign="middle"><a href="screenshots/reminder-card-small.png"><img src="screenshots/reminder-card-small.png" alt="小号" width="255"></a></td>
    <td align="center" valign="middle"><a href="screenshots/reminder-card-mini.png"><img src="screenshots/reminder-card-mini.png" alt="迷你" width="210"></a></td>
  </tr>
</table>

<p align="center">
  <b>折叠状态</b><br />
  <a href="screenshots/reminder-card-callapse.png"><img src="screenshots/reminder-card-callapse.png" alt="小窗提醒折叠状态" width="240"></a>
</p>

### 全屏提醒

纯色、渐变色、图片三种背景样式，支持多显示器。

<table>
  <tr>
    <th>纯色</th>
    <th>渐变色</th>
    <th>图片</th>
  </tr>
  <tr>
    <td align="center" valign="middle"><a href="screenshots/fullscreen-solid-color.png"><img src="screenshots/fullscreen-solid-color.png" alt="纯色" width="300"></a></td>
    <td align="center" valign="middle"><a href="screenshots/fullscreen-gradient.png"><img src="screenshots/fullscreen-gradient.png" alt="渐变色" width="300"></a></td>
    <td align="center" valign="middle"><a href="screenshots/fullscreen-wallpaper.png"><img src="screenshots/fullscreen-wallpaper.png" alt="图片" width="300"></a></td>
  </tr>
</table>

### 菜单栏

查看倒计时，随时立即休息、暂停或恢复提醒。

<p align="center">
  <a href="screenshots/menu-items.png"><img src="screenshots/menu-items.png" alt="菜单栏倒计时与快捷操作" width="421"></a>
</p>

### 应用界面

九张界面截图展示各项设置及浅色、深色外观。

<table>
  <tr>
    <th>通用设置</th>
    <th>休息方案</th>
    <th>工作时段</th>
  </tr>
  <tr>
    <td align="center" valign="middle"><a href="screenshots/1_mix.png"><img src="screenshots/1_mix.png" alt="通用设置" width="300"></a></td>
    <td align="center" valign="middle"><a href="screenshots/2_mix.png"><img src="screenshots/2_mix.png" alt="休息方案" width="300"></a></td>
    <td align="center" valign="middle"><a href="screenshots/3_mix.png"><img src="screenshots/3_mix.png" alt="工作时段" width="300"></a></td>
  </tr>
  <tr>
    <th>小窗提醒设置</th>
    <th>全屏渐变设置</th>
    <th>全屏图片设置</th>
  </tr>
  <tr>
    <td align="center" valign="middle"><a href="screenshots/4_mix.png"><img src="screenshots/4_mix.png" alt="小窗提醒设置" width="300"></a></td>
    <td align="center" valign="middle"><a href="screenshots/5_mix.png"><img src="screenshots/5_mix.png" alt="全屏渐变设置" width="300"></a></td>
    <td align="center" valign="middle"><a href="screenshots/6_mix.png"><img src="screenshots/6_mix.png" alt="全屏图片设置" width="300"></a></td>
  </tr>
  <tr>
    <th>显示器设置</th>
    <th>休息统计</th>
    <th>关于应用</th>
  </tr>
  <tr>
    <td align="center" valign="middle"><a href="screenshots/7_mix.png"><img src="screenshots/7_mix.png" alt="显示器设置" width="300"></a></td>
    <td align="center" valign="middle"><a href="screenshots/8_mix.png"><img src="screenshots/8_mix.png" alt="休息统计" width="300"></a></td>
    <td align="center" valign="middle"><a href="screenshots/9_mix.png"><img src="screenshots/9_mix.png" alt="关于应用" width="300"></a></td>
  </tr>
</table>

## Permissions

- **通知（可选）**：用于休息前预告和更新完成通知；未授权也能正常使用小窗和全屏提醒。
- **登录时启动（可选）**：开启后，系统可能要求在「登录项」中批准。

## Requirements

macOS 13（Ventura）或更新版本。支持 Apple Silicon 和 Intel。

## 开源许可

[AGPLv3](LICENSE)
