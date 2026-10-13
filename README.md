# Tick Rest

## 构建

在项目根目录执行，一次生成 Apple Silicon、Intel 和 Universal 三个 macOS Release 版本（需要安装并选中完整 Xcode）：

```bash
bash scripts/build-app.sh
```

产物位于 `dist/`，使用“应用名-平台-架构-构建模式”命名，最低支持 macOS 13：

| 产物 | 适用设备 |
| --- | --- |
| `Tick Rest-macOS-arm64-release.app` | Apple Silicon |
| `Tick Rest-macOS-x86_64-release.app` | Intel |
| `Tick Rest-macOS-universal-release.app` | Apple Silicon 和 Intel |

应用内显示名称仍为 `Tick Rest`。三份产物共用一次双架构编译。默认命令仅生成 Release；只有显式传入 `debug` 才会生成 Debug 产物。

“关于”页显示安装包的版本号、构建号、架构和构建模式，例如 `版本 0.1.0（构建 1）· Universal · Release`。版本号和构建号在 `packaging/Info.plist` 的 `CFBundleShortVersionString`、`CFBundleVersion` 中维护；架构和构建模式由脚本写入，与应用文件名无关。

也可以指定单个架构，`native` 自动选择本机架构：

```bash
bash scripts/build-app.sh release arm64
bash scripts/build-app.sh release x86_64
bash scripts/build-app.sh release universal
bash scripts/build-app.sh release native
```

需要 Debug 版本时，显式指定构建模式（省略架构参数会生成三份 Debug 产物）：

```bash
bash scripts/build-app.sh debug
bash scripts/build-app.sh debug universal
```

完整参数为 `[debug|release] [all|native|arm64|x86_64|universal]`，默认 `release all`。验证 Universal 产物包含两个架构：

```bash
lipo -archs "dist/Tick Rest-macOS-universal-release.app/Contents/MacOS/Tick Rest"
```

输出应包含 `arm64` 和 `x86_64`。当前脚本使用 ad-hoc 签名；正式分发还需要 Developer ID 签名和 Apple 公证。

验证三份 Release 产物的架构、签名、资源和最低系统版本：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/PackagingTests -v
```

测试 Debug 或单独构建的产物时，用环境变量选择，例如：

```bash
TICKREST_BUILD_CONFIGURATION=debug TICKREST_BUILD_ARCHITECTURE=native \
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/PackagingTests -v
```
