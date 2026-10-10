# TickRest · macOS 第一版

Swift 原生菜单栏休息提醒应用。只实现 macOS，首版界面为简体中文。

## 运行

构建完成后双击 `dist/TickRest.app`。应用常驻顶部菜单栏；关闭设置窗口不会退出。首次启动提供三步引导。

菜单包含状态和倒计时、立即护眼 / 起身休息、暂停提醒（15 分钟 / 1 小时 / 今天 / 手动恢复）、今日概览、设置、关于和退出。

设置采用原生 SwiftUI `NavigationSplitView` 侧栏和 `Form` 分组表单：通用、休息节奏、提醒样式、工作时段与免打扰、显示器、今日概览、数据与隐私、关于。当前页标题显示在窗口顶部；菜单的今日概览直接打开设置内的对应页面。

默认护眼 20 分钟 / 20 秒，起身 60 分钟 / 5 分钟。默认温和卡片需要点击开始；可主动选择到期自动开始的全屏遮罩。延期、跳过、提前结束、离席识别、全屏避让、锁屏 / 睡眠处理、跨午夜工作时段和本机统计均已接入。

自动离席默认在无键鼠输入 5 分钟后暂停，可在「工作时段与免打扰」中调整为 1–60 分钟或关闭。旧版配置升级时保留已有设置和统计，并为新增的离席时间采用 5 分钟默认值。

## 构建与检查

需要 macOS 13+、支持 Swift tools 6.0 的 Swift 工具链。可以使用 Xcode，也支持本机 Command Line Tools。

```bash
./scripts/test.sh
./scripts/build-app.sh
```

构建脚本将 Swift 模块缓存放在项目 `.build` 下，并将二进制、中文资源和图标打包进 `dist/TickRest.app`，采用开发用 ad-hoc 签名。默认产物对应本机架构，Apple Silicon 与 Intel 的双架构发布包需另行构建合并。

可选：重新生成自行绘制的应用图标。

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift scripts/make-icon.swift
iconutil -c icns packaging/AppIcon.iconset -o packaging/AppIcon.icns
```

SwiftPM 测试使用 Swift Testing；`test.sh` 已适配本机 Command Line Tools 的测试 Framework 路径。测试框架需要较新的测试宿主系统，不改变客户端的 macOS 13 部署目标。

## 目录

```text
Sources/TickRestCore/
  Engine.swift             独立状态机
  Models.swift             设置、提醒、统计事件和快照
  Persistence.swift        原子保存、90 天记录、今日统计
  Localization.swift       文案与日期 / 时长格式化入口
  Resources/zh-Hans.lproj/  中文翻译
Sources/TickRestApp/
  AppDelegate.swift        菜单栏、设置窗口、单实例
  AppController.swift      系统事件、设置与权限适配
  WindowCoordinator.swift  卡片、遮罩、多屏与预览
  SettingsView.swift       左侧菜单 / 右侧设置
  RestViews.swift          休息卡、遮罩、统计、首次引导
Tests/TickRestCoreTests/      计时、统计、恢复、本地化测试
packaging/                 应用元数据与图标
```

## 多语言扩展

应用名称统一配置在 `Sources/TickRestCore/Resources/AppIdentity.json` 的 `name` 字段中，SwiftPM 产品名、可执行文件、`.app` 名称、打包元数据与界面共用此配置。界面通过 `AppIdentity.name` 或 `L10n.text("app.name")` 读取，包含名称的翻译使用 `{appName}` 占位符；修改名称后重新构建即可生效。Swift 模块名和源码目录是稳定的内部标识，无需随显示名称再次修改。

所有界面文案都通过 `L10n.text` 读取 `.strings`。统计事件、设置值和状态机使用稳定标识，不保存翻译后的字符串。语言选择自动读取打包的语言资源；系统语言没有匹配翻译时回退简体中文。

增加英文的步骤：

1. 创建 `Sources/TickRestCore/Resources/en.lproj/Localizable.strings`，翻译中文文件的全部键。
2. 保留 `{appName}` 名称占位符及 `%@`、`%d` 等格式参数；如果语序调整，使用匹配的格式参数顺序，并同步扩展校验脚本。
3. 执行 `python3 scripts/check-localizations.py` 检查键与参数一致性，再运行测试。
4. 同步应用 `Info.plist` 的语言列表；如需翻译 Finder 中的应用名称，添加相应 `InfoPlist.strings` 并在打包脚本复制。
5. 验证最长文案、日期 / 星期显示、数字格式、键盘及 VoiceOver，再构建应用。

第一版仅包含简体中文。语言大小写匹配不依赖 SwiftPM 的目录名称规范化。

## 本地数据

保存于 `~/Library/Application Support/Restly/state.json`。使用原子写入保存设置、统计及计时快照；持续使用片段会合并，记录保留 90 天。首版采用 JSON 存储，后续数据规模增加时可迁移至 SQLite。

改名为 TickRest 后继续使用原有数据目录 `Restly` 和 Bundle ID `app.restly.desktop`，二者集中配置在 `AppIdentity.json`，作为兼容标识保留，以延续已有设置、统计和系统注册。

无账号、网络埋点、截图、按键记录、音视频采集或自动联网更新。可以在设置中清空统计；当前设置与周期不会随之清空。

## 当前发布边界

- `.app` 是本机开发构建，不是已完成 Developer ID 签名、公证的公开发行包。正式发布还需要开发者身份、签名 / 公证和安装渠道验证。
- 第一版通过窗口尺寸估算全屏；独占全屏和各类 Space 的行为需在目标系统实测。遇到误判可以关闭识别、手动暂停。
- 锁屏除了公开的工作区会话事件，也监听尽力而为的锁屏通知名称；不同 macOS 版本的覆盖情况需要真实锁屏测试，不依赖私有窗口控制接口。
- 无键鼠输入不等于真实离席，阅读 / 视频可能被误判。显式休息进行时不把无输入误判为离席，正常使用时可关闭离席识别。
- 自动会议识别、系统 Focus 自动跟随、周 / 月趋势、CSV 导出、自定义全局快捷键和在线更新不在这个本机版本内。
- 真实多显示器、睡眠唤醒、通知授权、开机启动、VoiceOver 和低功耗预算需要目标设备验证；核心规则单元测试不替代这些验证。

产品背景见 [产品需求文档](docs/休息提醒应用-产品需求文档.md)。
