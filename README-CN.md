# STC 串口控制面板（SwiftUI 版本）

一个基于 **SwiftUI + Combine + Darwin C API** 的 **macOS 桌面应用**，用于与下位机进行串口通信。  
它发送和接收固定长度的数据帧（6 字节，以 `AA 55` 开头），并提供简单的控制界面与日志系统。

[🔗 原版仓库（Python/Tkinter 版本）](https://github.com/Martin-YLX/DormitoryControlSystem)

---

## 📘 项目信息

- **项目名称**: STC 串口控制面板（SwiftUI）
- **完成时间**: 2025
- **课程**: 电子与计算机系统实训（2025 夏季学期）
- **使用软件**: Xcode (SwiftUI), Keil uVision

---

## ✨ 功能特性

- **开机动画**：显示进度条和班级/组员信息。
- **串口管理**：
  - 自动列出 `/dev/cu.*` 和 `/dev/tty.*` 下的可用串口。
  - 支持选择波特率（9600 ~ 230400）。
  - 一键连接 / 断开。
- **命令发送**：
  - 内置命令映射（门、灯、防忘带系统、护眼模式）。
  - iOS 风格的开关按钮绑定命令发送。
  - 支持手动输入 HEX。
- **日志系统**：
  - 打印发送（TX）和接收（RX）的 HEX 数据。
  - 自动处理粘包/半包，提取完整 6 字节帧。
  - 可滚动日志视图，自动滚动到最新消息。
- **自定义组件**：
  - 基于 `ToggleStyle` 实现的 iOS 风格开关动画。
  - 基于 SwiftUI `ProgressView` 的启动界面。

---

## 📝 通信协议

- **帧头**：`AA 55`
- **总长度**：6 字节
- **补齐/截断**：不足补 `00`，超长截断。

**示例**：

- 开灯：`AA 55 02 01 00 00`
- 关灯：`AA 55 02 00 00 00`

所有发送数据均通过 `buildFrameTotal6()` 处理，确保协议一致性。

---

## 📂 项目结构

```
.
├── SerialControlApp.swift   # 应用入口 @main
├── ContentView.swift        # 主界面布局
├── SerialClient.swift       # 串口通信封装
├── ViewModels.swift         # 状态与命令逻辑
├── README.md                # 英文文档
├── README-CN.md             # 中文文档
```

---

## 🚀 快速开始

### 1. 环境要求

- macOS 13+
- Xcode 15+
- Swift 5.9+

### 2. 构建与运行

1. 在 Xcode 中打开项目。
2. 选择 `My Mac` 作为运行目标。
3. 点击运行（⌘ + R）。

---

## 🔑 核心逻辑

1. **协议处理**
  - `parseHexString()`：解析 HEX 输入。
  - `buildFrameTotal6()`：强制补齐为 6 字节帧。
2. **串口通信**
  - `SerialClient`：封装 POSIX API (`open`, `tcsetattr`, `read`, `write`)，结合 `DispatchSourceRead` 实现异步接收。
3. **接收与分帧**
  - 累积数据到缓冲区。
  - 查找帧头 `AA 55`。
  - 提取定长 6 字节帧。
  - 打印原始片段 (`[RX HEX]`) 与完整帧 (`[RX FRAME]`)。
4. **命令接口**
  - `CMD_HEX`：命令表（如 `"LIGHT 1" → "AA 55 02 01"`）。
  - `sendCmd(key:)`：统一的命令发送入口。
