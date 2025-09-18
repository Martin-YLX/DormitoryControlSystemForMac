# STC Serial Control Panel (SwiftUI Version)

A **macOS desktop application** built with **SwiftUI + Combine + Darwin C APIs** for serial communication with microcontrollers.  
It sends and receives fixed-length frames (6 bytes, starting with `AA 55`) and provides a simple control interface with logging.

[📖 中文版说明 (README-CN.md)](README-CN.md)  
[🔗 Original Repository (Python/Tkinter Version)](https://github.com/Martin-YLX/DormitoryControlSystem)

---

## 📘 Project Information

- **Project Name**: STC Serial Control Panel (SwiftUI)
- **Completion Time**: 2025
- **Course**: Electronic and Computer Systems Training (Summer 2025)
- **Software Used**: Xcode (SwiftUI), Keil uVision

---

## ✨ Features

- **Startup Splash Screen**: Progress bar with class/team info.
- **Serial Port Management**:
  - Auto list available ports under `/dev/cu.*` and `/dev/tty.*`.
  - Select baud rate (9600 ~ 230400).
  - Connect / disconnect with one click.
- **Command Sending**:
  - Built-in command mappings (Door, Light, Anti-forget system, Eye-protection mode).
  - iOS-style toggle switches bound to command sending.
  - Manual HEX sending supported.
- **Logging System**:
  - Logs TX (sent) and RX (received) HEX data.
  - Handles sticky/partial packets, extracts complete 6-byte frames.
  - Scrollable log view with auto-scroll to latest message.
- **Custom Components**:
  - iOS-style `Toggle` animation using `ToggleStyle`.
  - SwiftUI `ProgressView` splash.

---

## 📝 Communication Protocol

- **Header**: `AA 55`
- **Total Length**: 6 bytes
- **Padding/Truncation**: Pad with `00` if shorter, truncate if longer.

**Examples**:

- Turn on light: `AA 55 02 01 00 00`
- Turn off light: `AA 55 02 00 00 00`

All outgoing data is processed through `buildFrameTotal6()` to ensure consistency.

---

## 🚀 Getting Started

### 1. Requirements

- macOS 13+
- Xcode 15+
- Swift 5.9+

### 2. Build & Run

1. Open project in Xcode.
2. Select `My Mac` as target.
3. Run (⌘ + R).

---

## 🔑 Core Logic

1. **Protocol Handling**
  - `parseHexString()`: Parse HEX input string.
  - `buildFrameTotal6()`: Enforce 6-byte frame format.
2. **Serial Communication**
  - `SerialClient`: Wraps POSIX APIs (`open`, `tcsetattr`, `read`, `write`) with `DispatchSourceRead`.
  - Supports async RX with callback.
3. **Receiving & Framing**
  - Accumulate data in buffer.
  - Locate frame header `AA 55`.
  - Extract fixed 6-byte frames.
  - Print both raw chunks (`[RX HEX]`) and parsed frames (`[RX FRAME]`).
4. **Command Interface**
  - `CMD_HEX`: Command table (`"LIGHT 1" → "AA 55 02 01"`).
  - `sendCmd(key:)`: Unified sending entry
