# cTerm

> **Alpha 版本** — 基本可用，但存在已知问题和功能缺失。使用前请阅读本文档。

原生 macOS 终端模拟器，基于 SwiftTerm + libssh2。支持本地 Shell、SSH 远程连接、Claude Code 集成和多标签 workspace。

## 安装

1. 下载 `cTerm.dmg`
2. 双击挂载，拖拽 `cTerm.app` 到 `Applications`
3. 首次打开：**右键 → 打开**（ad-hoc 签名，Gatekeeper 会弹警告）

## 功能

- 本地终端（zsh），基于 SwiftTerm 渲染
- SSH 远程连接（密码 / 密钥 / Agent 认证）
- 跳板机（Jump Host）
- 多标签 + 双栏分屏
- Workspace 管理（隔离工作目录）
- Claude Code 集成（一键启动会话）
- 侧边栏浮动面板（Hosts、File Transfer、AI 配置等）
- 终端主题预设（Matrix、Hacker Green、Amber Mono、Cyber Blue）
- SFTP 文件传输面板（双栏拖拽）

## 快捷键（终端内）

| 快捷键 | 功能 |
|--------|------|
| `Cmd+F` | 搜索 |
| `Cmd+C/V` | 复制/粘贴 |

## 依赖（开发）

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — 终端渲染引擎
- [libssh2](https://libssh2.org) — SSH 协议
- [libvterm](https://launchpad.net/libvterm) — VT100 解析
- [Citadel](https://github.com/orlandos-nl/Citadel) — SFTP 客户端

打包版本已内嵌 libvterm 和 libssh2，无需 Homebrew。

## 已知问题（Alpha）

- **窗口大幅缩放**：全屏或大幅扩大窗口后，Claude TUI 可能出现输入框偏移
- **切标签未聚焦**：点击标签标题不会自动获取键盘焦点，需要点击终端界面
- **内容因缩放丢失**：扩大窗口一定幅度后，终端部分区域可能出现渲染异常或内容漂移
- **无会话持久化**：关闭 app 后所有会话丢失
- **无 scrollback 搜索**：搜索仅在当前可见屏幕有效
- **SSH 未完整测试**：SSH 基本可用，边缘场景未充分测试
- **SFTP 功能有限**：支持拖拽下载，暂不支持上传拖拽
- **设置不实时生效**：字体/颜色修改后需新建终端

## 技术架构

```
cTerm
├── SwiftUI (AppUI)         — 主界面、视图、视图模型
├── SessionManager           — 会话生命周期、分屏、持久化
├── SSHClient               — SSH 连接、通道、SFTP（libssh2）
├── TerminalCore             — 终端模拟、解析器、屏幕缓冲
├── AIProvider              — AI API 集成
├── AIAssistant/AIAgent     — AI 辅助功能
└── HostStore               — 主机配置持久化
```

## 开发

```bash
# 环境要求
# macOS 14.0+, Xcode 16+, Swift 6.0

# 安装依赖
brew install libssh2 libvterm

# 构建
cd cTerm
swift build

# 运行
swift run

# 打包
swift build -c release
# 然后手动创建 .app bundle 和 DMG
```

## License

MIT
