# MyPaste

一个从零实现的原生 macOS 截图、标注与贴图工具。工作流参考 [Snipaste](https://zh.snipaste.com/)，核心截图、取色、标注、贴图、历史记录流程已对齐；使用 Swift + AppKit + ScreenCaptureKit，无 Electron、无 Web 运行时、无第三方依赖。

常驻菜单栏，按 **F1 截图**，按 **F3 贴图**。

![截图编辑器](docs/snapshots/02-overlay-editor.png)

## 功能

### 截图

- 拖拽区域截图、单击自动选中鼠标下的窗口、单击空白处选中整个屏幕。
- 多显示器分别冻结画面，选择区域限制在当前屏幕内。
- 像素级放大镜：显示十六进制色值、RGB、图像像素坐标；`C` 直接复制颜色。
- 选区支持 8 向手柄缩放、拖动移动、方向键 1px 微调、`Shift` 方向键缩放、`Shift` 拖拽锁定正方形。
- 工具栏显示当前截图像素尺寸，支持复制、保存、贴图、取消。
- 全屏截图快捷键 `⌥F1`：直接复制到剪贴板，可选自动保存。
- 独立取色器：冻结屏幕后单击复制颜色，支持跨屏。
- 截图过程不轮询屏幕，窗口检测只在鼠标移动时进行并做 120ms 节流。

### 标注

| 工具 | 说明 |
| --- | --- |
| 移动 | 调整选区位置 |
| 矩形 / 椭圆 | 可填充或描边，`Shift` 锁定宽高比 |
| 箭头 | 可调颜色、粗细，`Shift` 锁定 45° |
| 画笔 | 平滑曲线 |
| 荧光笔 | 半透明宽笔触 |
| 文字 | 透明底纯文字，无背景色 / 边框；点击原位输入，顶部手柄可拖动输入框；工具栏字号 12–80；提交后可选中移动、双击再编辑、改字号与颜色 |
| 马赛克 | 实时像素化，基于冻结画面采样 |
| 高斯模糊 | Core Image 实时模糊 |
| 序号 | 自动递增的圆形序号 |
| 橡皮擦 | 点击删除命中的标注 |

- 10 种颜色、6 档粗细、形状填充开关；文字使用独立字号菜单。
- 文字提交后自动切回移动工具并选中该文字，可直接拖动、用方向键微调、改字号 / 颜色，或双击重新编辑。
- 50 步撤销 / 重做（包含文字移动、字号与颜色修改）。
- 所有标注工具坐标统一以选区左上角为原点，编辑预览与最终输出共用同一套渲染器，保证所见即所得。
- 工具栏与快捷键：`V` 移动、`R` 矩形、`E` 椭圆、`A` 箭头、`B` 画笔、`H` 荧光笔、`T` 文字、`M` 马赛克、`U` 模糊、`N` 序号、`X` 橡皮擦。

### 输出 / 贴图

- 复制：PNG + TIFF 写入剪贴板。
- 保存：PNG / JPEG / TIFF，默认目录可在设置中修改。
- 复制后自动保存（可选）。
- 贴图：截图可以直接按 `P` 贴到屏幕原位置；剪贴板中的图片、文本、颜色值可以按 `F3` 生成贴图。
- 文本贴图渲染为深色卡片，颜色值生成色卡并保留原始文本用于复制。
- 贴图窗口支持：
  - 拖动移动、角点拖拽等比缩放、滚轮围绕鼠标缩放；
  - `⌥` + 滚轮调整透明度；
  - 右键菜单：复制文本 / 复制图片、保存、缩放、不透明度、始终置顶、隐藏、关闭；
  - 双击关闭；`Esc` / `Delete` / `⌘W` 关闭；方向键微调位置；
  - 菜单栏“显示 / 隐藏 / 关闭全部贴图”。
- 贴图不会随重启恢复；当前版本按会话管理。

### 历史与设置

- 历史记录自动保存到 `~/Library/Application Support/MyPaste/History`，保存缩略图。
- 历史窗口：缩略图网格、双击贴图、复制、保存、在 Finder 中显示、删除、清空、数量上限。
- 设置：三个全局快捷键的录制与恢复默认、冲突提示、失败提示；声音、放大镜、自动保存、保存目录、历史数量、开机启动、屏幕录制权限状态。
- 设置立即生效并写入 `UserDefaults`。
- 开机启动基于 `SMAppService.mainApp`；从非“应用程序”目录运行或未签名时，系统可能拒绝注册。

## 快捷键

### 全局

| 快捷键 | 动作 |
| --- | --- |
| `F1` | 区域截图 |
| `F3` | 贴图剪贴板 |
| `⌥F1` | 全屏截图到剪贴板 |

均可在“设置”中修改。

### 截图编辑器

| 快捷键 | 动作 |
| --- | --- |
| `Enter` | 复制并完成 |
| 双击选区内 | 复制并完成 |
| `P` | 贴图并完成 |
| `S` | 保存 |
| `C` | 复制鼠标位置颜色 |
| `⌘C` | 复制截图 |
| `⌘S` | 保存 |
| `⌘Z` / `⇧⌘Z` | 撤销 / 重做 |
| `⌘A` | 全选当前屏幕 |
| `↑ ↓ ← →` | 移动选区 1px（按住 `⌥` 为 10px） |
| `⇧↑ ↓ ← →` | 缩放选区 |
| `Esc` | 取消截图（文字编辑时仅取消文字） |

### 贴图窗口

| 快捷键 | 动作 |
| --- | --- |
| 拖动 | 移动贴图 |
| 滚轮 / `⌥` + 滚轮 | 缩放 / 调整透明度 |
| 角点拖拽 | 等比缩放 |
| `⌘C` | 复制文本（若有）或图片 |
| `⌘S` | 保存 |
| `↑ ↓ ← →` | 移动 1px（`Shift` 为 10px） |
| `Esc` / `Delete` / `⌘W` / 双击 | 关闭 |

## 性能

本机实测（macOS 27.0.1，arm64，内置显示器 3840×2560 / 1920×1280pt）：

| 指标 | MyPaste 1.0.0 | Snipaste 2.8.3 |
| --- | ---: | ---: |
| 空闲常驻内存 RSS | 71.4 MB（73,104 KB） | 124.0 MB（127,024 KB） |
| 空闲 CPU | 0.0% | 0.0% |
| 应用体积 | 2.6 MB | 88 MB |
| 运行时依赖 | 系统 AppKit / ScreenCaptureKit | 自带 Qt 等 |

测量方法：两个应用均只常驻菜单栏、无可见窗口，启动完成数秒后执行 `ps -o rss`。RSS 包含共享内存页，因此只用于相对比较。相对 Snipaste，常驻 RSS 约低 42%，应用体积约小 97%。

实现上的开销控制：

- 原生 AppKit 视图与 Core Graphics 绘制，无 WebView / JS 运行时。
- 截图底图是静态图层，交互层单独重绘；选区外遮罩只绘制矩形区域。
- 窗口检测完全由鼠标事件驱动，并做 120ms 缓存节流，没有定时器轮询。
- 设置、历史、偏好窗口全部惰性创建；历史窗口关闭时释放缩略图缓存。
- 截图会话结束后立刻释放屏幕帧、窗口和工具栏；历史 PNG 编码与自动保存放到后台队列。
- 文本 / 颜色贴图在 2x 离屏上下文中渲染。

说明：本环境尚未为 MyPaste 授予 macOS 屏幕录制权限，因此没有测量真实抓屏延迟。抓屏使用系统 ScreenCaptureKit，延迟取决于显示器数量、分辨率和系统版本。

## 构建与运行

要求：macOS 14+，Xcode 15+（本项目在 macOS 27.0.1 / Xcode 27.1 / Swift 6.4 验证）。

```bash
# 构建 release .app（ad-hoc 签名）
./scripts/build_app.sh

# 运行构建产物
open build/MyPaste.app
```

本次交付的构建已安装到 `/Applications/MyPaste.app`，并已在该路径完成屏幕录制授权。应用是菜单栏应用（`LSUIElement`），不会出现在 Dock。

> 注意：如果重新执行构建脚本或替换应用，ad-hoc 签名会变化，macOS 可能要求重新授予屏幕录制权限。

### 首次授权

1. 启动 MyPaste，菜单栏出现取景框图标。
2. 按 `F1` 或菜单栏“截图”。macOS 会请求“屏幕录制”权限。
3. 在“系统设置 › 隐私与安全性 › 屏幕录制”中勾选 MyPaste。
4. 如果授权后仍提示无权限，请退出 MyPaste 再重新打开（系统可能要求重启进程）。
5. 如果移动了 `.app` 或重新签名，TCC 可能需要重新授权。发布给他人时建议使用稳定的 Developer ID 签名并公证。

### 开发

```bash
swift build
swift test
swift run MyPasteSnapshots docs/snapshots
```

- `swift test`：21 个核心测试 + 11 个画布交互测试，共 32 个，全部通过。
- `swift run MyPasteSnapshots docs/snapshots`：离屏渲染 10 张 UI 预览与 1 张合成结果，不弹出窗口，也不需要屏幕录制权限。
- 调试时也可通过 URL 动作：

```bash
open 'mypaste://capture'
open 'mypaste://pin'
open 'mypaste://fullscreen'
open 'mypaste://picker'
open 'mypaste://history'
open 'mypaste://settings'
open 'mypaste://quit'
```

## 验证状态

已自动验证：

- 选区几何、手柄缩放、移动约束、像素坐标换算。
- 标注渲染、最终合成、文字透明底、马赛克 / 模糊采样区域。
- 历史记录写入、缩略图、上限裁剪、删除。
- 颜色 / 文本贴图卡片渲染与颜色解析。
- 画布交互：拖拽选区、点选全屏、矩形标注、序号、橡皮擦、文字提交、输入框拖动、字号调整、文字对象移动与再次编辑、撤销 / 重做、选区缩放、导出合成。
- 离屏 UI 快照：悬浮放大镜、编辑器与完整工具栏、文字输入框与字号菜单、取色器、贴图、历史、设置、文本 / 颜色卡片。
- 运行进程验证：菜单栏进程启动、空闲 CPU 0%、贴图窗口（图片 / 文本）、设置 / 历史窗口、全局快捷键注册成功、URL 动作。

已完成端到端验证：

- `/Applications/MyPaste.app` 获得系统“屏幕录制”授权后，全屏截图成功：剪贴板收到 3840×2560 PNG，历史目录写入原图与缩略图。
- 区域截图覆盖层实际出现：1920×1280 pt、窗口层级 1000 的全屏覆盖窗口；切换到其他应用后按设计自动取消。
- 全屏截图和区域覆盖层使用同一套 `ScreenCaptureKit` 采集结果；编辑器内的选区、标注、撤销、文字输入与导出合成覆盖于 11 个画布交互测试。
- 测试产生的真实屏幕截图与剪贴板内容已在验证后清理，未保留用户屏幕内容。

仍建议用户按下面清单做一次人工交互验收（自动化进程无法代替鼠标授权/点击）：

- [ ] `F1` 拖拽选区，放大镜 / 色值 / 尺寸显示正常，`Enter` 复制后可粘贴到其他应用。
- [ ] 未拖拽时单击一个窗口可自动选中窗口范围。
- [ ] 多显示器时每块屏幕都被冻结，可在任意屏幕开始选择。
- [ ] 矩形 / 箭头 / 文字 / 马赛克 / 模糊 / 序号 / 橡皮擦、撤销与重做正常。
- [ ] `S` 保存、`P` 贴图、`F3` 贴剪贴板图片 / 文本 / 颜色。
- [ ] 贴图滚轮缩放、`⌥` 滚轮透明度、右键菜单、双击关闭正常。
- [ ] 历史窗口双击贴图、复制、删除。
- [ ] 在设置中修改快捷键后无需重启即可生效。

## 与 Snipaste 的差异

已实现的核心工作流：

- 截图（区域 / 窗口 / 全屏）、冻结屏幕、放大镜、像素取色。
- 截图标注工具齐全，撤销 / 重做、颜色 / 粗细 / 填充。
- 图像 / 文本 / 颜色贴图，缩放、透明度、置顶、多贴图管理。
- 历史记录、可配置全局快捷键、开机启动、自动保存。
- 菜单栏常驻，占用低。

当前版本未实现：

- 非文字标注创建后的再次选择 / 修改属性（文字标注已支持选中移动、双击编辑、改字号与颜色）。
- 跨显示器的一次性选区（每块屏幕单独选择）。
- 窗口内部的 UI 元素级自动识别（目前为窗口级）。
- 长截图 / 滚动截图、GIF 录制、OCR、贴图分组、贴图跨重启持久化、云同步 / 上传。
- 多行文字标注（文本贴图卡片支持多行）。
- 高度自定义的工具栏顺序和快捷键组合。

## 架构

```text
Sources/
├── MyPasteCore/                 # 无业务 UI，可单元测试的核心
│   ├── Annotation.swift         # 标注模型、命中测试、文字度量
│   ├── AnnotationRenderer.swift # 预览/导出共用渲染器
│   ├── ImageComposer.swift      # 选区裁剪 + 标注合成
│   ├── ClipboardCard.swift      # 文本/颜色贴图卡片、离屏渲染
│   ├── HistoryStore.swift       # 历史持久化、缩略图、裁剪
│   ├── ImageExporter.swift      # PNG/JPEG/TIFF、剪贴板读写
│   ├── Shortcut.swift           # Carbon 键码/修饰键与显示名
│   ├── AppSettings.swift        # UserDefaults 设置
│   └── Geometry.swift           # 选区、手柄、约束与几何
├── MyPasteUI/
│   ├── ScreenCaptureService.swift
│   ├── HotKeyCenter.swift       # Carbon 全局快捷键
│   ├── CaptureController.swift  # 权限、抓屏、复制/保存/贴图分发
│   ├── CaptureSession.swift     # 多屏覆盖窗口生命周期、保存面板
│   ├── SelectionCanvasView.swift# 选区、放大镜、窗口检测、标注与文字对象交互
│   ├── TextEditingBox.swift     # 可拖动文字输入框、字号与内联编辑
│   ├── EditorToolbarView.swift  # 自绘工具栏、字号菜单
│   ├── WindowDetector.swift     # CGWindowList 窗口命中
│   ├── PinWindowController.swift# 贴图窗口、缩放、右键菜单
│   ├── PinBoard.swift
│   ├── HistoryWindowController.swift
│   ├── PreferencesWindowController.swift
│   ├── ShortcutRecorderButton.swift
│   ├── AppDelegate.swift        # 菜单栏、生命周期、URL Scheme、权限引导
│   └── DebugSnapshots.swift     # 离屏 UI 预览（开发辅助）
├── MyPaste/AppMain.swift        # @main
└── MyPasteSnapshots/            # 快照 CLI
Tests/
├── MyPasteTests/                # 核心测试
└── MyPasteUITests/              # 画布交互测试
Resources/
├── Info.plist
├── AppIcon.icns
└── AppIcon.png
```

设计要点：

- 屏幕截图冻结后按显示器分别建立无边框覆盖窗口；静态底图与交互层分离，避免每次鼠标移动重绘整张截图。
- 选区、标注都在 point 坐标系中编辑，导出时按屏幕 backing scale 一次性光栅化，保留 Retina 清晰度。
- 标注预览与最终导出共用 `AnnotationRenderer`，避免“编辑时”和“输出时”不一致。
- 所有内容在本机处理，不发送网络请求，不需要账号。

## 隐私

- 无网络代码、无分析统计、无上传。
- 截图历史默认保存在本机 `~/Library/Application Support/MyPaste/History`。
- 屏幕内容只在内存中处理，会话结束后释放；历史文件需用户主动删除或设置上限。
- 剪贴板读写仅在用户触发截图 / 贴图时发生。

## 预览

| | |
| --- | --- |
| ![窗口检测与放大镜](docs/snapshots/01-overlay-hover.png) | ![取色器](docs/snapshots/03-overlay-colorpicker.png) |
| ![文字输入与字号调整](docs/snapshots/10-text-editor.png) | ![导出合成](docs/snapshots/04-composition.png) |
| ![贴图窗口](docs/snapshots/07-pin.png) | ![历史记录](docs/snapshots/09-history.png) |
| ![设置](docs/snapshots/08-preferences.png) | ![文本贴图](docs/snapshots/05-card-text.png) |

更多预览见 [`docs/snapshots`](docs/snapshots)。

---

MyPaste 是独立实现，不包含 Snipaste 的任何代码或资源。Snipaste 是其各自权利人的产品。
