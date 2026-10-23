<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Inkwell icon"><br>
  <a href="README.md">English</a> · <b>简体中文</b>
</p>

# Inkwell

**一款原生的 macOS [Typst](https://typst.app) 编辑器**：SwiftUI/AppKit 界面，底层是内嵌 Typst 0.15.1 编译器的 Rust 内核。左边写，右边边打字边看到清晰的矢量页面实时更新。

![Inkwell 编辑 Typst 文稿与实时预览](docs/images/screenshot.jpg)

## 功能

**实时预览**
- 页面直接根据 Typst 的排版结果按矢量绘制，不生成位图，任意缩放都清晰
- 增量更新：只重新传输、重绘有变化的页面
- 点击预览中的任意内容跳到对应源码；预览会跟随光标位置
- 缩放、适配宽度（可锁定）、画廊模式、页码跳转、预览拆分为独立窗口
- 把预览锁定到某个文件、暂停实时预览、导出 PDF（或就地导出）

**编辑器**
- 基于 TextKit 2，支持 Typst 语法高亮、行号、当前行高亮
- 带占位符的自动补全、悬停文档、⌘ 点击跳到定义
- 括号自动闭合、列表自动续写、注释/复制行、粗体/斜体/下划线/标题/列表/公式快捷命令
- 拼写检查只针对正文，代码不会被画红线
- Vim 键位（普通/插入/可视模式），支持相对行号
- 7 套主题、字体与字号设置、动画光标、圆角选区、打字音效
- 多标签页、自动存储；文件在磁盘上被其他程序修改时给出提示

**项目**
- 侧栏：文件、全项目查找替换（包含/整词/前缀/正则）、大纲、符号、诊断
- 符号：可搜索全部 `sym` 和 `emoji` 符号，也可以**手绘**，由 [Detypify](https://github.com/QuarticCat/detypify) 模型识别
- BibTeX（`.bib`）条目编辑器，图片与 PDF 查看
- Typst Universe 包（自动下载、管理已下载的包），本地包命名空间
- 用任意 Typst Universe 模板新建项目
- 对依赖旧版本的文稿，可按需下载 Typst 0.11–0.14 编译器
- 内置完整的 Typst 官方文档，离线可用，支持搜索和“拷贝为 Markdown”
- 界面支持简体中文、English、Deutsch、Français、Español、Italiano、Nederlands、Português

## 安装

从 [Releases](../../releases) 下载 `Inkwell-<版本>.dmg`，打开后把 Inkwell 拖进“应用程序”。

应用使用临时签名，未经过 Apple 公证。第一次打开时请右键点按 Inkwell → **打开**，或者运行：

```bash
xattr -dr com.apple.quarantine /Applications/Inkwell.app
```

需要 Apple 芯片的 Mac，macOS 15 或更新版本。

## 从源码构建

需要：macOS 15+、Xcode 16+ 命令行工具（Swift 6）、Rust 稳定版。

```bash
scripts/build-core.sh        # Rust 内核 → 静态库 + Swift 绑定
scripts/build-docs.sh        # 可选：从 Typst 仓库构建离线文档
scripts/bundle.sh release    # → build/Inkwell.app
scripts/package.sh           # → build/Inkwell-<版本>.dmg 和 .zip
scripts/run.sh samples/demo  # 在某个文件夹上启动
```

## 测试

```bash
cd core && cargo test --release   # 编译、绘制指令、补全、双向跳转、手绘识别、性能
scripts/selftest.sh               # 在 app 内驱动真实的编辑器和预览
scripts/selftest.sh network       # Typst Universe 索引与模板项目
scripts/selftest.sh legacy        # 下载 Typst 0.13.1 并用它编译
```

## 实现原理

| 路径 | 内容 |
| --- | --- |
| `core/` | Rust crate：Typst `World`（磁盘文件 + 未存储的编辑内容 + 包）、页面 → 二进制绘制指令编码、IDE 能力（补全、悬停、跳转）、包与模板、符号识别。通过 UniFFI 暴露给 Swift。 |
| `app/` | Swift 包：窗口、编辑器、Core Graphics 预览渲染、侧栏、设置、文档浏览器 |
| `scripts/` | 构建、打包、文档、图标、本地化和测试脚本 |
| `docs/STATUS.md` | 功能清单 |

预览从不把页面转成位图：内核把每一页的排版结果序列化成紧凑的绘制指令（字形、路径、图片、填充），app 用 Core Graphics 绘制。字形轮廓和图片只取一次并缓存；渐变和平铺图案由内核预先采样。

## 致谢

Inkwell 的设计受 [Edist](https://edist.app) 启发。本项目独立开发，与 Edist 和 Typst 均无关联，也未获得其认可。

基于 [Typst](https://github.com/typst/typst)（Apache-2.0）、[Detypify](https://github.com/QuarticCat/detypify)（MIT）、[UniFFI](https://github.com/mozilla/uniffi-rs)（MPL-2.0）、[tract](https://github.com/sonos/tract)、ureq 和 rustls 构建。内置文档版权归 Typst GmbH 及贡献者所有（Apache-2.0）。

## 许可证

[Apache License 2.0](LICENSE)
