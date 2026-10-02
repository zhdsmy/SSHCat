# Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)（规则见 [AGENTS.md](AGENTS.md#版本号与发布)）。

## [Unreleased]

## [0.3.0] - 2026-10-03

### 新增

- 保存并连接、连接失败或退避期间立即重试，以及供终端手动执行的首次连接命令。
- 主机选择器支持搜索、刷新和递归读取 SSH config 的 `Include`；支持 IPv6 主机、转发端点及对应监听冲突检查。
- 规则 JSON 导入导出：导入前预览、重复规则跳过或复制、全新 ID、关闭自动启动，并在保存成功后一次性添加。
- 菜单端口摘要、运行中 / 失败筛选、包含规则名称的端口冲突提示，以及通知和登录项的系统授权状态与设置入口。

### 修复

- 统一编辑与运行按钮的脏状态判断，等值端口和首尾空白不再产生无法保存的伪草稿。
- 在字段旁展示校验错误，空白及无效端口文本不会丢失；退出时确认是否放弃草稿，返回编辑保留连接。

### 文档

- README 默认英文，简体中文移至 `README.zh-Hans.md`；截图换成对应语言的 2x 全貌图（菜单栏面板 + 管理窗口）。

### English

- Add Save and Connect, Retry Now, and a first-connection command to copy into Terminal.
- Support searchable, refreshable SSH host suggestions with Include expansion, IPv6 hosts and endpoints, and address-aware listener conflicts.
- Add JSON import/export with preview, duplicate handling, fresh IDs, automatic startup disabled, and atomic persistence before adding rules.
- Show menu endpoint summaries, running/failed filters, named conflict warnings, and actual macOS notification/login-item approval status.
- Normalize pending edits, retain invalid port text with inline errors, and protect unsaved drafts when quitting.
- README now defaults to English, with Simplified Chinese in `README.zh-Hans.md`; screenshots are replaced by a localized 2x overview of the menu bar panel and management window.

## [0.2.0] - 2026-10-02

### 新增

- 统一 i18n 架构：菜单、管理窗口、设置、使用说明、校验错误、通知及诊断支持英语、简体中文和繁体中文。
- 默认跟随系统语言，不支持的语言回退英语；可在设置选择语言，下次启动生效，不中断现有转发，也不改写用户规则。
- 增加完整英文 README，与简体中文版本互相跳转，并提供对应语言的界面截图。
- 三种语言的隔离快照、翻译键与格式参数完整性检查；App 和 universal DMG 携带完整 SwiftPM 语言资源。

### English

- Add English, Simplified Chinese, and Traditional Chinese throughout the app using native localization catalogs.
- Follow the system language by default, with a language override in Settings that takes effect on the next launch.
- Add an English README, language links, localized screenshots, and checks for translation coverage and formatting.

## [0.1.1] - 2026-10-02

### 新增

- 借鉴 TailCat 的原生菜单栏与管理体验：按名称、主机或端口搜索，三类转发快捷新建、规则副本、内置使用说明及复制反馈。
- 设置中手动检查 GitHub 最新版本并打开下载页，仅在点击检查时联网。
- 隔离的 debug 界面快照与 README 示例截图，覆盖深浅色、空白、失败、重连、草稿、搜索、窄窗口、长名称和配置错误。

### 优化

- 菜单显示状态文字与运行数量，多规则可滚动；详情固定操作栏，目标和转发字段保留标签，日志与等价命令可折叠。
- macOS 14 及以上通过原生 SettingsLink 打开设置，macOS 13 保留兼容入口。

### 修复

- 先保存再应用规则变更；保存失败不丢失草稿、不重启或删除原连接，错误提示在菜单和管理窗口可见。
- 区分不存在、读取失败、未来版本与损坏配置；备份失败时阻止覆盖，修复后可重新加载，保持 v1 数据兼容。
- 菜单与详情一致阻止启动有未保存修改的已停止规则；副本使用独立 ID 且默认不自动启动。

## [0.1.0] - 2026-09-30

首个公开版本。

### 新增

- 菜单栏列出所有转发规则，一键开关，显示运行状态；菜单栏图标是戴着 `>_` 提示符的猫头，有转发运行时为实心。
- 以 ssh 报告认证成功作为“运行中”的判据，连不上的主机 10 秒内失败；重连时显示实时倒计时，失败时给出处理建议（如需先在终端确认主机指纹）。
- 一条规则对应一次 `ssh -N`，同一目标上可混用本地（`-L`）、远程（`-R`）、动态（`-D`）转发；主机可从 `~/.ssh/config` 的 Host 中选择，端口、密钥可按规则覆盖。
- 进程监管：`ssh` 退出后按指数退避重连，系统唤醒或网络变化后重启运行中的规则；崩溃后只清理被 launchd 收养的遗留 `ssh` 子进程，不误伤用户自己的会话。
- 可复制等价的 `ssh` 命令和诊断信息；实际启动一律以 argv 执行，不经 shell。
- 管理窗口：未保存的修改在切换规则后保留，本机端口冲突时提示；日志区自动滚动到最新。
- 设置：自定义 `ssh` 路径（校验可执行）、显示 `ssh -V` 版本、系统通知（管理窗口在前台时同样弹出）、登录启动。
- 数据文件 0600、目录 0700、原子写入；不保存密码或私钥内容。
- 以 universal（Apple 芯片 + Intel）DMG 发布，ad-hoc 签名，未经 Apple 公证。

[Unreleased]: https://github.com/zhdsmy/SSHCat/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/zhdsmy/SSHCat/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/zhdsmy/SSHCat/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/zhdsmy/SSHCat/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/zhdsmy/SSHCat/releases/tag/v0.1.0
