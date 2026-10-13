# Tick Rest 完整测试报告（2026-10-14）

以下为修复前的审计记录；修复和最终复验结果见文末。

本轮确认 **3 个产品问题、1 个文档问题**。另外，原有 3 个原生测试存在时序或预期维护问题，应与产品缺陷分开处理。业务源码未修改；新增核心测试、原生测试和独立进程启动脚本，保留失败断言供后续修复回归。

测试对象：HEAD `ff3ed2b1776417c11d95e305377f7c61df67695a` 的业务源码及工作区现有 README。环境为 macOS 15.7.7（24G720）、Intel x86_64、Swift 6.1.2、Xcode MacOSX15.5 SDK，实际连接两块屏幕。测试使用临时存档、独立实例锁；启动实测使用独立 bundle ID。没有退出正在运行的正式 App，也没有通过测试修改它的设置、统计、通知权限或登录项。

## 最终结果

最终全量 Swift 执行 **357 个函数：351 通过、6 失败、0 跳过**。其中核心 236 个（235 通过、1 失败），应用 XCTest 121 个（116 通过、5 失败）。6 个失败函数包含 3 个产品缺陷回归和上文所述 3 个原有测试维护事项；34 条失败断言不能计作 34 个缺陷。完整测试入口退出码为 1。

核心执行行覆盖率 **98.09%（1389/1416）**，应用模块 **81.85%（5897/7205）**，来自最后一轮两份原始 profile。业务源码/资源的 SHA-256 校验通过，测试前后未改变。

| 检查 | 结果 |
| --- | --- |
| 原有核心回归 | 初轮 232 个函数全部通过，历史核心审计失败未再出现 |
| 新增核心用例 | 4 个函数、20 个参数场景；暂停重启用例的 4 个零进度场景失败，其余通过 |
| 混合动作压力测试 | 四种计划各 5,000 步，共 20,000 步；400 次存档保存/加载检查通过 |
| 统计守恒 | 四种计划各 100 次“工作→休息→暂停→离开→返回→跳过”循环通过，共 400 次 |
| 工作时段矩阵 | 普通、跨夜、00:00 和 23:59 边界，共 40,320 个逐分钟检查通过 |
| 原生页面、卡片、控件 | 真实 AppKit/SwiftUI 渲染、按钮动作、菜单、欢迎流程、侧栏、主题、颜色、壁纸及统计清除等已执行；失败分类见下文 |
| 双屏 | 实际两屏的指针选屏、动作归属、卡片尺寸/位置、屏幕变化重建、Esc 保持等原生测试通过 |
| 独立 `.app` 进程实测 | 8/8：真实入口初始化、状态栏、定时器、重复进程退出、首进程保持、重复启动打开设置、退出存盘、重新获取实例锁 |
| Debug 构建 | arm64、x86_64、Universal 全部成功 |
| Release 构建 | arm64、x86_64、Universal 全部成功 |
| 打包验证 | Debug 36/36，Release 36/36；共 72 项通过 |
| 本地化资源 | 415 个键 × 5 种语言一致性检查通过；资源通过不代表运行中的控件会刷新 |
| 脚本及格式 | Python AST、shell 语法及 `git diff --check` 通过 |

打包检查包括可执行文件、bundle ID、版本/构建信息、资源与源码一致性、图标、ad-hoc 签名、Mach-O 架构、最低部署版本及动态链接依赖。交叉编译 arm64 和声明 macOS 13 不等于在对应硬件或系统上运行通过。

## 已确认的问题

### FULL-01 · P2 · 重启后切换计划会丢失零进度的暂停休息

1. 任选四种预设，手动开始短休息。
2. 在第一个计时 tick 前立即暂停，此时提醒 `elapsed == 0`。
3. 保存快照并重启，暂停及 deferred 提醒都被恢复。
4. 应用另一休息计划。

预期：如同不重启的暂停休息，保留当前提醒和原计划，新计划等待当前休息结算后生效。

实际：新计划立即安装，旧提醒被清除，`pendingPlan` 为 nil；用户仍处于暂停状态。四种预设的零进度场景均失败，已休息 1 秒的四个对照场景通过。

原因：暂停休息通过 `pausedRestID` 区分已经开始但尚未累计时长的提醒，该字段没有保存到 Snapshot，恢复时也未重建。`applyPlan` 只依赖当前 resting、elapsed>0 或该 ID，因此把恢复的零进度暂停休息当成可直接替换的提醒。

定位：[Engine.swift:30](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/Sources/TickRestCore/Engine.swift:30)、[applyPlan:100](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/Sources/TickRestCore/Engine.swift:100)。

证据：[新增核心测试](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/Tests/TickRestCoreTests/ComprehensiveAudit20261014Tests.swift:11)，函数 `pausedRestSurvivesRestartThenPlanReplacement`。通过 Snapshot 的实际 JSON 编解码和新引擎实例复现；本轮未声称通过人工退出/重开正式 App 复现这一边界。

### FULL-02 · P3 · 定时暂停到期后，已打开菜单的操作仍是“恢复提醒”

1. 设置一个有限期限的暂停，进入实际 NSMenu 的 `menuWillOpen` 生命周期。
2. 在同一个菜单对象保持打开状态时，让引擎 tick 到暂停截止时间。
3. 等待 revision 对应的主线程刷新。

预期：暂停结束后显示“暂停提醒”子菜单，并移除“恢复提醒”。

实际：引擎 pause 已为 nil，状态文字为 `Reminders active`，但菜单仍保留 `Resume reminders`，缺少 Pause。重新打开菜单会重建，因此影响范围是已打开菜单的持续刷新。

原因：菜单重建条件比较计划、提醒种类、是否休息、是否有提醒及语言，遗漏暂停状态。普通状态文本会更新，操作项不更新。

定位：[AppDelegate.swift:104](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/Sources/TickRestApp/AppDelegate.swift:104)。

证据：[原生测试](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/Tests/TickRestAppTests/PauseMenuRegressionTests.swift)，函数 `testOpenMenuReplacesResumeActionWhenTimedPauseExpires`，两条失败断言及菜单标题日志。本轮调用真实菜单生命周期和真实 model 更新，未用鼠标保持 macOS 原生菜单事件跟踪循环。

### FULL-03 · P3 · 运行中切换语言，小窗样式页的下拉选项保留旧语言

1. 以英文打开“样式”页，选择小窗提醒。
2. 将应用语言依次改为简体、繁体、日文、韩文，保留同一页面实例。
3. 检查实际 Picker 当前选项及可访问性树。

预期：下拉当前选项和页面说明都使用新语言。

实际：侧栏、字段标题、帮助文字已翻译，但当前选项仍为 `Reminder card`、`Normal`、`Automatic`、`Glass`。四种非英文语言 × 四个选项共 16 条断言失败；英文对照全部通过。提前提醒秒数也在截图中保留 `10 sec`，未额外计入断言数。

原因：普通 Form 和全屏样式页通过 `.id(model.interfaceLanguage)` 重建 macOS 缓存的 Picker，小窗样式页改成单个 ScrollView 后遗漏了这一处理。

定位：[SettingsView.swift:162](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/Sources/TickRestApp/SettingsView.swift:162)。

证据：函数 `testVisiblePickerSelectionsRefreshAfterLiveLanguageChange`；[简体中文截图](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/.build/full-audit-20261014/actual-minimum-zh-Hans.png)、[韩文截图](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/.build/full-audit-20261014/actual-minimum-ko.png)。静态新建五语言页面的测试全部通过，不能替代此项运行中语言切换检查。

### FULL-04 · P3 · README 的产物名称和实际构建结果不一致

README 宣称产物为 `Tick Rest-macOS-arm64-release.app`、`Tick Rest-macOS-x86_64-release.app`、`Tick Rest-macOS-universal-release.app`，并给出相应 lipo 命令。

实际 `bash scripts/build-app.sh release all` 生成 `Tick Rest-arm64.app`、`Tick Rest-x86_64.app`、`Tick Rest-universal.app`。README 的三个目录均不存在，按文档复制命令会找不到文件。Debug 产物同样采用 `-架构-debug.app` 形式。

定位：[README.md:11](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/README.md:11)、[build-app.sh](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/scripts/build-app.sh)。本轮保留了工作区原有 README 修改，没有替用户决定采用哪套命名。

## 需要维护或明确预期的原有测试

这三个失败函数在初轮和专项复跑均出现；没有修改断言或将它们强制改绿。

| 测试 | 本轮证据与判断 |
| --- | --- |
| `testLaunchWelcomeFinishesWithoutOpeningSettingsAndManualReopenUsesOneWindow` | 在打开窗口后的同步时刻读取 minSize，得到高度 657，而测试要求 708。新诊断在等待工具栏布局 400ms 后得到 frame/min/contentMin 均为 890×708，并通过最小尺寸断言。属于读取时机问题；本轮未再复现历史“永久允许缩至严重裁切”的缺陷。初次展示有 51 点高度调整，但没有将它认定为严重裁切。 |
| `testGentleAppearanceScrollsAsOnePageAtMinimumSize` | 无条件要求 document 高度大于 viewport、滚到底后必须进入 scrolled 状态。本轮中文内容 691 点而 viewport 708 点，内容已经容得下，无需滚动。应根据是否实际溢出检查滚动。本轮五语言最小窗口截图已生成；中文完整显示主要控件。 |
| `testRoundMenuShowsFocusOnceAfterEarlyEndAndUpdatesWhileOpen` | 只在暂停后的五语言断言失败。测试要求保留完全匹配 `plan.focus_state` 的文字，当前菜单保留的是“完成第 N 轮后的休息”上下文 `roundRestText`，状态项则改成暂停。需要统一现有轮次休息文案与旧断言的合同，不能仅据精确字符串不匹配声称轮次数据丢失。 |

编译还产生了测试辅助函数访问 AppKit actor 隔离属性、旧 NSAccessibility 接口弃用的警告；当前包使用 Swift 5 language mode，构建成功。这些警告属于测试代码维护事项。

## 实测与覆盖边界

- 原生桌面控制接口禁用；已通过测试进程创建真实 NSWindow/NSPanel、运行真实 SwiftUI 控件，并通过本进程可访问性动作操作按钮。另启动独立、签名的 `.app` 进程验证入口、定时器和实例锁。没有将这些测试称为人工鼠标逐项验收。
- 本轮生成至少 117 张新的原生测试截图，另有 5 张实际最小设置窗口截图和一张 45 页面缩略总览。已检查五语言页面总览以及英语/中文/韩语样式页细图；没有将全部截图生成等同于逐张视觉验收。
- 实际两屏上的窗口测试已执行；屏幕参数变化测试包含发送真实通知观察者路径，**没有物理拔插线缆**。
- Workspace 睡眠/会话离开测试使用通知事件和确定性时间。**没有触发真实睡眠、单独锁屏、注销登录或重启电脑**；历史报告的物理通过记录没有算进本轮。
- 使用独立通知测试身份先读取系统权限，当前结果为 `notDetermined`（rawValue 0）；因此未请求授权，未弹出权限选择框。历史 AUDIT-06 的拒绝文案问题本轮未复现，也未认定已修复。真实允许/拒绝、通知投递与登录启动仍需相应系统条件。
- 六种声音资源解析及按钮路径有自动化覆盖，未人工听辨扬声器输出；VoiceOver、外部应用真实全屏识别、Apple Silicon 执行、macOS 13 实机运行仍未验收。
- 覆盖率为执行行覆盖率，不是分支覆盖率；未覆盖组合、系统 API 状态和感知效果不能由覆盖率推定正确。

## 复跑与证据

```bash
# 全量 Swift 测试，包含本轮新增失败回归
bash scripts/test.sh --no-parallel --enable-code-coverage

# 本轮核心专项
bash scripts/test.sh --no-parallel --filter ComprehensiveAudit20261014Tests

# 本轮原生专项
bash scripts/test.sh --no-parallel --filter 'testOpenMenuReplacesResumeActionWhenTimedPauseExpires|testSettingsMinimumAfterToolbarSettlesAndAppearanceControlsRender|testVisiblePickerSelectionsRefreshAfterLiveLanguageChange'

# 独立进程实测
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-launch-audit.py

# Release 三架构构建及打包验证
bash scripts/build-app.sh release all
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/PackagingTests -v
```

日志集中于 [.build/full-audit-20261014](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/.build/full-audit-20261014)：`final-swift.log`、`targeted.log`、`native-diagnostics.log`、`language-picker.log`、`release-build.log`、`release-packaging.log`、`launch/summary.json`、`notification-run.log`。`source-sha256.json` 保存业务源码和资源的指纹，`screenshot-manifest.json` 列出本轮原生截图。

最终机器可读结果为 [summary.json](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/.build/full-audit-20261014/summary.json)，覆盖率原文为 `final-coverage-core.log`、`final-coverage-app.log`，合并 profile 为 `final-coverage.profdata`。本轮所有独立测试进程已退出，测试 App 和临时存档保留在 `.build` 供复跑，没有注册测试登录项或发出通知授权请求。

首轮完整自动化入口的构建、打包及覆盖率原始日志位于 [.build/functional-audit/20261014-005156-23683](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/.build/functional-audit/20261014-005156-23683)。所有失败均保留失败退出码，不以“已知失败”跳过。

## 修复跟进（2026-10-14）

按 FULL-01 至 FULL-04 的顺序修复，并分别提交：

| 问题 | 修复 | Commit |
| --- | --- | --- |
| FULL-01 | 保存/恢复已开始的暂停休息 ID；校验 ID 与 deferred 提醒对应；未开始的等待提醒仍允许替换 | `321c615` |
| FULL-02 | 菜单打开期间检测暂停状态变化，重建暂停/恢复操作 | `1be52cc` |
| FULL-03 | 小窗样式页按界面语言更新视图 identity，刷新原生 Picker 的当前选项 | `b300570` |
| FULL-04 | 构建和打包测试采用 README 约定的“应用名-macOS-架构-构建模式”命名 | `a715a31` |

三个旧测试已维护：窗口最小尺寸等待工具栏布局完成（最多 1 秒，保留所有尺寸断言）；滚动分隔线按实际内容是否溢出检查；暂停后的菜单验证一次休息轮次上下文，并检查引擎轮次和休息类型。两个递归 AppKit 辅助函数补充 MainActor 隔离。没有跳过失败测试。

核心专项 237 个函数通过；菜单专项同时覆盖自然到期和重新暂停；运行中五语言 Picker 回归通过。维护专项 4 个原生测试通过。Debug/Release 各生成 arm64、x86_64、Universal 三份安装包，各 36 项打包检查全部通过。

修复后的测试日志位于 [.build/fix-audit-20261014](/Users/mayuxiao/amateur/tick-rest/tick-rest-macos/.build/fix-audit-20261014)。原生回归拆分为 `PauseMenuRegressionTests.swift`、`LiveLanguageRegressionTests.swift` 和 `SettingsMinimumRegressionTests.swift`。已目视检查修复后的简体样式页截图，下拉已选文字均使用简体中文。

最终全量复验退出码 **0**：核心 **237/237 通过**；原生 XCTest **116 通过、0 失败、5 条件跳过**，共 **358 个函数：353 通过、0 失败、5 跳过**。这次原生进程只识别到一块屏幕，五个真实双屏用例按原有 XCTSkip 条件跳过；修复前双屏通过记录不计入本次复验通过数。独立签名 `.app` 进程启动验证 **8/8 通过**，所有测试进程已退出。

合并本次 XCTest 和 Swift Testing 的两份原始 profile 后，核心执行行覆盖率 **98.10%（1394/1421）**，应用 **81.64%（5887/7211）**。原始输出保存在 `coverage-TickRestCore.log`、`coverage-TickRestApp.log`；合并文件为 `final-coverage.profdata`。Shell/Python 语法检查和 `git diff --check` 通过。旧的 NSAccessibility 弃用警告仍存在，未更换底层测试辅助接口。

本次仍未验证 Apple Silicon/macOS 13 实机、真实通知允许/拒绝、登录启动、物理睡眠/锁屏及人工听辨声音；这些与修复前报告的系统条件边界一致。
