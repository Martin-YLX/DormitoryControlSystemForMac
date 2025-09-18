import SwiftUI
import Combine
import Foundation
import Darwin

let FRAME_HEAD: [UInt8] = [0xAA, 0x55]
let FRAME_LEN: Int = 6
let DEFAULT_BAUD: Int = 115200
let DEFAULT_PORT: String = "None"
let LOG_EVERY_N_RX: Int = 0  // 0 = 全部打印

let CMD_HEX: [String: String] = [
    "DOOR 1":   "AA 55 01 01",
    "DOOR 0":   "AA 55 01 00",
    "LIGHT 1":  "AA 55 02 01",
    "LIGHT 0":  "AA 55 02 00",
    "EYE 1":    "AA 55 03 01",
    "EYE 0":    "AA 55 03 00",
    "ANTI 1":   "AA 55 04 01",
    "ANTI 0":   "AA 55 04 00",
]

func bytesToHex(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

enum HexParseError: Error, LocalizedError {
    case oddLength
    case illegalByte(String)
    var errorDescription: String? {
        switch self {
        case .oddLength: return "HEX 串长度应为偶数"
        case .illegalByte(let b): return "非法HEX字节: \(b)"
        }
    }
}

func parseHexString(_ s: String) throws -> Data {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: " ")
    if trimmed.isEmpty { return Data() }
    let toks = trimmed.split{ $0.isWhitespace }.map(String.init)
    if toks.count == 1 {
        var hex = toks[0].replacingOccurrences(of: "0x", with: "", options: .regularExpression)
        if hex.count % 2 != 0 { throw HexParseError.oddLength }
        var out = Data(); out.reserveCapacity(hex.count/2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            let byteStr = String(hex[idx..<next])
            guard let b = UInt8(byteStr, radix: 16) else { throw HexParseError.illegalByte(byteStr) }
            out.append(b)
            idx = next
        }
        return out
    } else {
        var out = Data()
        for t in toks {
            let bstr = t.replacingOccurrences(of: "^0x", with: "", options: .regularExpression)
            guard bstr.range(of: "^[0-9a-fA-F]{1,2}$", options: .regularExpression) != nil,
                  let b = UInt8(bstr, radix: 16) else { throw HexParseError.illegalByte(t) }
            out.append(b)
        }
        return out
    }
}

func buildFrameTotal6(_ raw: Data) throws -> Data {
    guard raw.count >= 2, Array(raw.prefix(2)) == FRAME_HEAD else {
        throw NSError(domain: "app", code: 1, userInfo: [NSLocalizedDescriptionKey: "帧必须以 AA 55 开头（总长6字节协议）"])
    }
    if raw.count < FRAME_LEN { return raw + Data(repeating: 0x00, count: FRAME_LEN - raw.count) }
    return raw.prefix(FRAME_LEN)
}

final class SerialClient: ObservableObject {
    @Published private(set) var isOpen: Bool = false
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "serial.read.queue")
    var onBytes: ((Data) -> Void)?

    func openPort(port: String, baud: Int) throws {
        guard !isOpen else { return }
        fd = port.withCString { cstr in
            Darwin.open(cstr, O_RDWR | O_NOCTTY | O_NONBLOCK)
        }
        if fd < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "无法打开串口 \(port)，请确认设备驱动或 Sandbox 设置（建议开发期关闭 Sandbox）"])
        }

        var tio = termios()
        if tcgetattr(fd, &tio) != 0 { Darwin.close(fd); throw posixError("tcgetattr 失败") }

        cfmakeraw(&tio)
        tio.c_cflag |= (tcflag_t(CLOCAL) | tcflag_t(CREAD))
        tio.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        tio.c_cflag |= tcflag_t(CS8)

        withUnsafeMutablePointer(to: &tio.c_cc) { ptr in
            ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { arr in
                arr[Int(VMIN)]  = 0
                arr[Int(VTIME)] = 1
            }
        }

        let speed: speed_t = speed_t(baudToConstant(baud))
        if cfsetispeed(&tio, speed) != 0 || cfsetospeed(&tio, speed) != 0 {
            Darwin.close(fd); throw posixError("设置波特率失败")
        }
        if tcsetattr(fd, TCSANOW, &tio) != 0 {
            Darwin.close(fd); throw posixError("tcsetattr 失败")
        }

        tcflush(fd, TCIOFLUSH)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = Darwin.read(self.fd, &buf, buf.count)
            if n > 0 { self.onBytes?(Data(buf.prefix(n))) }
        }
        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fd >= 0 { Darwin.close(self.fd) }
            self.fd = -1
        }
        readSource = src
        src.resume()
        isOpen = true
    }

    func closePort() {
        guard isOpen else { return }
        readSource?.cancel()
        readSource = nil
        isOpen = false
    }

    func send(_ data: Data) throws {
        guard isOpen, fd >= 0 else {
            throw NSError(domain: "app", code: 2, userInfo: [NSLocalizedDescriptionKey: "串口未连接"])
        }
        let sent = data.withUnsafeBytes { ptr -> Int in
            Darwin.write(fd, ptr.baseAddress!, data.count)
        }
        if sent < 0 { throw posixError("写串口失败") }
    }

    private func posixError(_ msg: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: msg + ": " + String(cString: strerror(errno))])
    }

    private func baudToConstant(_ baud: Int) -> Int32 {
        switch baud {
        case 9600: return Int32(B9600)
        case 19200: return Int32(B19200)
        case 38400: return Int32(B38400)
        case 57600: return Int32(B57600)
        case 115200: return Int32(B115200)
        case 230400: return Int32(B230400)
        default: return Int32(B115200)
        }
    }

    static func listPorts() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: "/dev") else { return [DEFAULT_PORT] }
        let cu = items.filter { $0.hasPrefix("cu.") || $0.hasPrefix("tty.") }
        let paths = cu.map { "/dev/\($0)" }.sorted()
        return paths.isEmpty ? [DEFAULT_PORT] : ([DEFAULT_PORT] + paths)
    }
}

final class AppViewModel: ObservableObject {
    @Published var ports: [String] = SerialClient.listPorts()
    @Published var selectedPort: String = DEFAULT_PORT
    @Published var baud: Int = DEFAULT_BAUD
    @Published var status: String = "未连接"
    @Published var logLines: [String] = []
    @Published var hexInput: String = "AA 55 01 01"

    @Published var doorOn = false
    @Published var lightOn = false
    @Published var antiOn = false
    @Published var eyeOn  = false

    private var rxBuf = Data()
    private var rxChunkCounter = 0

    let serial = SerialClient()

    init() {
        serial.onBytes = { [weak self] data in
            DispatchQueue.main.async { self?.handleIncoming(data) }
        }
    }

    func refreshPorts() {
        ports = SerialClient.listPorts()
        if !ports.contains(selectedPort) { selectedPort = DEFAULT_PORT }
    }

    func toggleConn() {
        if serial.isOpen {
            serial.closePort()
            status = "未连接"
            appendLog("[SYS] 串口已断开")
        } else {
            do {
                try serial.openPort(port: selectedPort, baud: baud)
                status = "已连接 \(selectedPort) @ \(baud)"
                appendLog("[SYS] 已连接: \(selectedPort) @ \(baud)")
            } catch {
                appendLog("[ERR] 打开失败: \(error.localizedDescription)")
            }
        }
    }

    func sendCmd(key: String) {
        do {
            guard let hex = CMD_HEX[key] else {
                throw NSError(domain: "app", code: 3, userInfo: [NSLocalizedDescriptionKey: "未配置的命令映射：\(key)"])
            }
            let raw = try parseHexString(hex)
            let frame = try buildFrameTotal6(raw)
            try serial.send(frame)
            appendLog("[TX HEX] \(bytesToHex(frame))  (\(key))")
        } catch {
            appendLog("[ERR] 发送失败: \(error.localizedDescription)")
        }
    }

    func sendHexManual() {
        do {
            let raw = try parseHexString(hexInput)
            let frame = try buildFrameTotal6(raw)
            try serial.send(frame)
            appendLog("[TX HEX] \(bytesToHex(frame))  (HEX手动发送)")
        } catch {
            appendLog("[ERR] 发送失败: \(error.localizedDescription)")
        }
    }

    private func handleIncoming(_ data: Data) {
        rxChunkCounter += 1
        if LOG_EVERY_N_RX > 0 {
            if rxChunkCounter % LOG_EVERY_N_RX == 0 {
                appendLog("[RX HEX] \(bytesToHex(data))  (每\(LOG_EVERY_N_RX)条打印一次)")
            }
        } else {
            appendLog("[RX HEX] \(bytesToHex(data))")
        }
        rxBuf.append(data)
        extractFrames()
    }

    private func extractFrames() {
        let head = Data(FRAME_HEAD)
        while let r = rxBuf.range(of: head) {
            if r.lowerBound > 0 { rxBuf.removeSubrange(0..<r.lowerBound) }
            guard rxBuf.count >= FRAME_LEN else { return }
            let frame = rxBuf.prefix(FRAME_LEN)
            rxBuf.removeFirst(FRAME_LEN)
            appendLog("[RX FRAME] \(bytesToHex(frame))")
        }
    }

    private func appendLog(_ line: String) {
        let ts = DateFormatter.cachedTime.string(from: Date())
        logLines.append("[\(ts)] \(line)")
        if logLines.count > 2000 { logLines.removeFirst(logLines.count - 2000) }
    }
}

fileprivate extension DateFormatter {
    static let cachedTime: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()
}

struct IOSSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { withAnimation(.easeOut(duration: 0.12)) { configuration.isOn.toggle() } }) {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(configuration.isOn ? Color.green.opacity(0.72) : Color.gray.opacity(0.35))
                    .frame(width: 54, height: 30)
                Circle()
                    .fill(.white)
                    .shadow(radius: 1, y: 1)
                    .frame(width: 26, height: 26)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("iOS Switch")
    }
}

struct OnChangeCompat<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            content.onChange(of: value) { newValue in action(newValue) }
        }
    }
}

struct ContentView: View {
    @StateObject var vm = AppViewModel()
    @State private var showSplash = true

    var body: some View {
        ZStack {
            mainView.opacity(showSplash ? 0 : 1)
            if showSplash { SplashView().transition(.opacity) }
        }
        .frame(minWidth: 780, minHeight: 560)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeIn(duration: 0.25)) { showSplash = false }
            }
        }
    }

    private var mainView: some View {
        VStack(alignment: .leading, spacing: 10) {
            topHeader
            connectionPanel
            controlPanel
            hexSendPanel
            logPanel
        }.padding(12)
    }

    private var topHeader: some View {
        HStack {
            Text("STC 串口控制面板").font(.system(size: 18, weight: .bold))
            Spacer()
            Text("智能2301班 — 组长：张兆涵  组员：岳林轩").foregroundStyle(.secondary)
        }
    }

    private var connectionPanel: some View {
        GroupBox("串口连接") {
            Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("端口:").gridColumnAlignment(.trailing)
                    Picker("", selection: $vm.selectedPort) {
                        ForEach(vm.ports, id: \.self) { Text($0) }
                    }
                    .frame(width: 360)
                    Button("刷新端口") { vm.refreshPorts() }
                    Spacer(minLength: 12)
                }
                GridRow {
                    Text("波特率:")
                    Picker("", selection: $vm.baud) {
                        ForEach([9600, 19200, 38400, 57600, 115200, 230400], id: \.self) { Text("\($0)") }
                    }
                    .frame(width: 180)
                    Button(vm.serial.isOpen ? "断开" : "连接") { vm.toggleConn() }
                        .keyboardShortcut(.return, modifiers: [.command])
                    Text(vm.status).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 6)
        }
    }

    private var controlPanel: some View {
        GroupBox("控制面板") {
            Grid(horizontalSpacing: 16, verticalSpacing: 14) {
                controlCell(title: "门", isOn: $vm.doorOn, onKey: "DOOR 1", offKey: "DOOR 0")
                controlCell(title: "灯", isOn: $vm.lightOn, onKey: "LIGHT 1", offKey: "LIGHT 0")
                controlCell(title: "防忘带系统", isOn: $vm.antiOn, onKey: "ANTI 1", offKey: "ANTI 0")
                controlCell(title: "护眼模式", isOn: $vm.eyeOn, onKey: "EYE 1", offKey: "EYE 0")
            }.padding(.horizontal, 6)
        }
    }

    private func controlCell(title: String, isOn: Binding<Bool>, onKey: String, offKey: String) -> some View {
        GridRow {
            Text(title + "：").font(.system(size: 13, weight: .semibold)).gridColumnAlignment(.leading)
            Toggle("", isOn: isOn)
                .toggleStyle(IOSSwitchStyle())
                .modifier(OnChangeCompat(value: isOn.wrappedValue) { newVal in
                    vm.sendCmd(key: newVal ? onKey : offKey)
                })
            Text("当前：" + (isOn.wrappedValue ? "开" : "关")).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var hexSendPanel: some View {
        GroupBox("HEX 发送") {
            HStack(spacing: 8) {
                TextField("AA 55 01 01", text: $vm.hexInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("发送") { vm.sendHexManual() }
                    .keyboardShortcut(.return)
            }.padding(.horizontal, 6)
        }
    }

    private var logPanel: some View {
        GroupBox("日志") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(vm.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }.padding(6)
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: vm.logLines.count) { _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(vm.logLines.count - 1, anchor: .bottom)
                    }
                }
            }.frame(minHeight: 180)
        }
    }
}

struct SplashView: View {
    @State private var progress: Double = 0
    var body: some View {
        VStack(spacing: 14) {
            Text("STC 串口控制面板").font(.system(size: 20, weight: .bold))
            Text("智能2301班  —  组长：张兆涵   组员：岳林轩").foregroundStyle(.secondary)
            ProgressView(value: progress, total: 100)
                .frame(width: 320)
                .onAppear {
                    let start = Date()
                    Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { t in
                        let dt = Date().timeIntervalSince(start)
                        progress = min(100, dt / 1.6 * 100)
                        if dt >= 1.6 { t.invalidate() }
                    }
                }
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 12)
    }
}

@main
struct SerialControlApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.titleBar)
            .defaultSize(width: 8000, height: 560)
    }
}
