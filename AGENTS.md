# AGENTS.md

给在本仓库工作的开发者和 AI Agent 的约定。等级：【MUST】必须 /【SHOULD】推荐 /【MUST NOT】禁止。

## 项目

SSHCat 是管理长期运行 SSH 端口转发的 macOS 菜单栏工具（SwiftUI + Swift Package）。App 不实现 SSH 协议，只以子进程方式执行 `ssh -N`，并负责监管、重连与状态展示。

| 路径 | 内容 |
| --- | --- |
| `Sources/SSHCatCore/Model/` | `ForwardRule.swift`（规则、转发类型、校验与 ssh argv 构造）、`ForwardStore.swift`（`forwards.json` 读写、`SecureFile`）、`AppSettings.swift`（UserDefaults 偏好） |
| `Sources/SSHCatCore/Runtime/` | `ForwardRunner.swift`（单条规则的 ssh 进程与状态机）、`ForwardManager.swift`（所有规则的监管，UI 的数据源）、`BackoffPolicy.swift`（重连退避）、`SystemEvents.swift`（唤醒 / 网络变化）、`PIDTracker.swift`（子进程 pid 落盘，清理孤儿进程）、`ProcessBox.swift`、`BinaryLocator.swift`（查找 ssh）、`SSHConfigHosts.swift`（`~/.ssh/config` 里的 Host）、`ShellQuote.swift`（复制等价命令）、`Diagnostics.swift`（复制诊断信息） |
| `Sources/SSHCat/` | 菜单栏 App：`SSHCatApp.swift`（入口与场景）、`MenuContent.swift`（菜单栏面板）、`ManageView.swift`（管理窗口）、`SettingsView.swift`（设置）、`MenuBarIcon.swift`（代码绘制的菜单栏图标）、`Common.swift`（状态文案、实时倒计时、剪贴板）、`ViewState.swift`（`@ViewState` 别名） |
| `Tests/SSHCatCoreTests/` | Swift Testing 单测，用 `/bin/sh` 脚本冒充 ssh |
| `Resources/` | `Info.plist`（版本号唯一来源）、`AppIcon.icns`（由脚本生成） |
| `scripts/` | 打包、DMG、发布说明、图标 |
| `.github/workflows/` | CI（build + test）与 Release（推 tag 发布 DMG） |

【MUST NOT】`SSHCatCore` 依赖 SwiftUI/AppKit，保证可单测。

## 工具链与常用命令

- swift-tools 5.9，最低 macOS 13；本地只需 Command Line Tools。
- 【MUST】不使用 SwiftUI 宏：CLT 没有 `SwiftUIMacros` 插件，`@State` 会被解析成宏而无法编译，`#Preview`、`@Observable` 同理。视图状态用 `@ViewState`（`State` 的别名，按属性包装器展开，见 `ViewState.swift`）。
- 【MUST】新 API 若高于 macOS 13，须 `if #available` 兜底。

```bash
swift build                                                           # debug 构建
swift build --product SSHCatPackageTests && swift test --skip-build   # 单测（CLT 下 swift test 需先单独构建测试产物）
./scripts/bundle.sh                        # build/SSHCat.app（release，ad-hoc 签名）
UNIVERSAL=1 ./scripts/make-dmg.sh          # build/SSHCat-<版本>.dmg + .sha256（arm64 + x86_64）
./scripts/release-notes.sh <版本>          # 打印该版本的 Release 正文
swift scripts/make-icon.swift              # 重新生成 Resources/AppIcon.icns
```

图标：App 图标由 `scripts/make-icon.swift` 矢量绘制，改图后重新运行并提交生成的 `Resources/AppIcon.icns`。菜单栏图标不在资源里，而是在 `Sources/SSHCat/MenuBarIcon.swift` 中用代码绘制（模板图像，空闲为描边、有转发运行时为实心）；`MenuBarExtra` 按名字只会去 asset catalog 里找图，裸 SwiftPM 可执行文件没有它，所以不要改回按名字加载。

## 代码规范

- 【MUST】改代码同步更新相关注释、单测和 README；复杂逻辑（argv 构造、校验、状态机、退避、数据迁移）必须有单测。
- 【MUST】数据文件格式（`forwards.json` 等）变化须向后兼容读取旧格式并带迁移测试；偏好设置键改名同理。
- 【SHOULD】注释解释“为什么”（约束、取舍、ssh 的行为怪癖），一眼能看懂的代码不写注释。
- 【SHOULD】小而聚焦的改动，贴合周围代码的命名和风格；不做无关重构。
- 界面文案使用简体中文；命令行参数、代码标识符保持英文原样。

## 安全与隐私

- 【MUST】调用 ssh 一律以 argv 形式 exec，不经 shell；用户输入（主机、用户、绑定地址、密钥路径等）须校验，不能以 `-` 开头以免被当成参数。
- 【MUST】保持 `BatchMode=yes`：App 不弹密码框、不代为接受主机密钥；新主机需用户先在终端里连一次。
- 【MUST】数据文件 0600、目录 0700、原子写入。
- 【MUST NOT】保存密码或读取私钥内容；密钥只以路径形式传给 `ssh -i`。
- 【MUST NOT】在仓库（代码、测试、示例数据、截图、文档、提交信息）中出现真实的主机名、IP、用户名、邮箱或个人路径；示例数据一律虚构（如 `devbox`、`app`、`/Users/me`、`192.168.1.10`）。
- 【MUST NOT】自动化流程（Agent、脚本、CI）对真实用户数据启动 App 或真实 ssh 连接；单测用 `/bin/sh` 假 ssh。

## Git 与提交

- 功能开发用短分支 + PR，合入 `main` 前须 CI 的 `build-test` 通过。
- 【MUST】提交信息遵循 Conventional Commits：`<type>(<scope>): <subject>`，type 取 `feat` / `fix` / `refactor` / `docs` / `test` / `build` / `ci` / `chore`；subject 简短，中英文皆可。
- 【MUST】提交前确认可编译、单测通过。
- 【MUST NOT】提交构建产物与本机状态：`.build/`、`build/`、`*.dmg`、`.DS_Store`、编辑器/Agent 目录（已在 `.gitignore`）。
- 【MUST】提交作者使用 GitHub noreply 邮箱，不用个人或公司邮箱。

## 版本号与发布

- 【MUST】遵循 [SemVer](https://semver.org/lang/zh-CN/) `MAJOR.MINOR.PATCH`：
  - 1.0 之前：新功能、数据格式或行为的不兼容变化升 MINOR；仅修复升 PATCH。
  - 1.0 之后：不兼容变化升 MAJOR，新功能升 MINOR，修复升 PATCH。
- 【MUST】版本号唯一来源是 `Resources/Info.plist` 的 `CFBundleShortVersionString`；`CFBundleVersion` 为整数，每次发布加 1，永不回退。
- 【MUST】tag 格式 `vX.Y.Z`，且必须与 `CFBundleShortVersionString` 一致（Release 工作流会校验，不一致直接失败）。
- 【MUST】`CHANGELOG.md` 的变更先记在 `## [Unreleased]` 下，发布时改成 `## [X.Y.Z] - YYYY-MM-DD` 并更新文末链接；发布说明从这一节生成，没有这一节发布会失败。

发布步骤：

1. 更新 `Resources/Info.plist`（`CFBundleShortVersionString`、`CFBundleVersion` + 1）和 `CHANGELOG.md`。
2. 本地验证：单测通过，`UNIVERSAL=1 ./scripts/make-dmg.sh` 成功。
3. 提交 `chore(release): vX.Y.Z`，推送 `main` 并等 CI 通过。
4. `git tag vX.Y.Z && git push origin vX.Y.Z`；`release.yml` 会构建 universal DMG、生成 `.sha256` 并创建 GitHub Release。
5. 发布有误时删除 Release 与 tag，修复后用新的 PATCH 版本重新发布，不复用已发布的版本号。

App 仅 ad-hoc 签名、未经 Apple 公证；如果将来接入 Developer ID 签名与公证，在 `bundle.sh` / `release.yml` 中实现并更新 README 的安装说明。
