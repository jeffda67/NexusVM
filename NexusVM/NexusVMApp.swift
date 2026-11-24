import SwiftUI
import Observation
import UniformTypeIdentifiers
import Darwin
import UIKit
import Network
import ObjectiveC

// MARK: - Darwin csops JIT Bridge

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

private enum CSFlags {
    static let opsStatus: UInt32 = 0
    static let debugged: UInt32 = 0x1000_0000
}

// MARK: - UTType Extensions

extension UTType {
    static let isoImage = UTType(filenameExtension: "iso") ?? UTType("public.iso-image") ?? .data
    static let qcow2Image = UTType(filenameExtension: "qcow2") ?? UTType("com.nexusvm.qcow2-image") ?? .data
    static let rawDiskImage = UTType(filenameExtension: "img") ?? UTType("com.nexusvm.raw-disk-image") ?? .data
    static let vmDiskTypes: [UTType] = [.isoImage, .qcow2Image, .rawDiskImage, .data]
}

// MARK: - Design System

enum NexusTheme {
    static let bg = Color(hex: 0x0D0E12)
    static let card = Color(hex: 0x16181F)
    static let elevated = Color(hex: 0x1D202A)
    static let border = Color(hex: 0x232630)
    static let cyan = Color(hex: 0x00E5FF)
    static let amber = Color(hex: 0xFFB300)
    static let emerald = Color(hex: 0x00E676)
    static let crimson = Color(hex: 0xFF4D6A)
    static let textPrimary = Color(hex: 0xF3F5F9)
    static let textSecondary = Color(hex: 0x9097AA)
    static let textMuted = Color(hex: 0x5B6275)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

extension View {
    func nexusCard(elevated: Bool = false, borderColor: Color = NexusTheme.border, radius: CGFloat = 14) -> some View {
        self
            .background(elevated ? NexusTheme.elevated : NexusTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(borderColor, lineWidth: 1))
    }

    func sectionTag(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary)
    }
}

// MARK: - Domain Models

enum OSPreset: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case linux = "Linux", windows = "Windows", macOS = "macOS", customISO = "Custom ISO"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .linux: return "terminal.fill"
        case .windows: return "square.grid.2x2.fill"
        case .macOS: return "apple.logo"
        case .customISO: return "opticaldisc.fill"
        }
    }
    var tint: Color {
        switch self {
        case .linux: return NexusTheme.cyan
        case .windows: return Color(hex: 0x4DA6FF)
        case .macOS: return Color(hex: 0xD2DAE8)
        case .customISO: return NexusTheme.amber
        }
    }
    var defaultArch: CPUArchitecture { (self == .linux || self == .macOS) ? .arm64 : .x86_64 }
    var defaultMode: ExecutionMode { (self == .linux || self == .macOS) ? .virtualize : .emulate }
    var defaultRAM: Int { (self == .windows || self == .macOS) ? 4096 : 2048 }
    var defaultStorage: Int {
        switch self {
        case .linux: return 24
        case .windows, .macOS: return 64
        case .customISO: return 16
        }
    }
}

enum ExecutionMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case virtualize = "Virtualize", emulate = "Emulate"
    var id: String { rawValue }
    var subtitle: String { self == .virtualize ? "ARM64 Hypervisor / Fast TCG" : "TCG dynamic binary translation (JIT)" }
}

enum CPUArchitecture: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case x86_64 = "x86_64", arm64 = "ARM64", riscV = "RISC-V"
    var id: String { rawValue }
    var dylibName: String {
        switch self {
        case .arm64: return "libqemu-aarch64-softmmu.dylib"
        case .x86_64: return "libqemu-x86_64-softmmu.dylib"
        case .riscV: return "libqemu-riscv64-softmmu.dylib"
        }
    }
    var binaryName: String {
        switch self {
        case .arm64: return "qemu-system-aarch64"
        case .x86_64: return "qemu-system-x86_64"
        case .riscV: return "qemu-system-riscv64"
        }
    }
    var machineFlag: String {
        switch self {
        case .arm64: return "virt,highmem=off"
        case .x86_64: return "q35"
        case .riscV: return "virt"
        }
    }
}

enum GraphicsRenderer: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case metal = "Metal", angle = "ANGLE", vga = "VGA"
    var id: String { rawValue }
    var deviceFlag: String { self == .vga ? "VGA,vgamem_mb=64" : "virtio-gpu-pci" }
}

enum NetworkMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case nat = "NAT", bridged = "Bridged"
    var id: String { rawValue }
    var netdevFlag: String {
        self == .nat ? "user,id=net0,hostfwd=tcp::2222-:22" : "vmnet-bridged,id=net0,ifname=en0"
    }
}

enum VMStatus: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case stopped = "Stopped", running = "Running", paused = "Paused"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .stopped: return NexusTheme.textMuted
        case .running: return NexusTheme.emerald
        case .paused: return NexusTheme.amber
        }
    }
}

struct VirtualMachine: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var osPreset: OSPreset
    var mode: ExecutionMode
    var architecture: CPUArchitecture
    var cpuCores: Int
    var ramMB: Int
    var storageGB: Int
    var renderer: GraphicsRenderer
    var networkMode: NetworkMode
    var diskImagePath: String = ""
    var customQEMUArgs: String = ""
    var status: VMStatus = .stopped
    var createdAt: Date = Date()
    var lastBootedAt: Date?

    var diskFileName: String {
        diskImagePath.isEmpty ? "No Disk Attached" : URL(fileURLWithPath: diskImagePath).lastPathComponent
    }
    var formattedRAM: String {
        (ramMB >= 1024 && ramMB % 1024 == 0) ? "\(ramMB / 1024) GB" : "\(ramMB) MB"
    }

    func buildQEMUArguments(spicePort: UInt16 = 5930, qmpPort: UInt16 = 4444) -> [String] {
        var argv = [
            architecture.binaryName,
            "-M", architecture.machineFlag,
            "-accel", "tcg,thread=multi",
            "-cpu", "max",
            "-smp", "\(cpuCores)",
            "-m", "\(ramMB)",
            "-device", renderer.deviceFlag,
            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-device", "usb-tablet",
            "-netdev", networkMode.netdevFlag,
            "-device", "virtio-net-pci,netdev=net0",
            "-spice", "port=\(spicePort),addr=127.0.0.1,disable-ticketing=on",
            "-qmp", "tcp:127.0.0.1:\(qmpPort),server,nowait"
        ]
        if !diskImagePath.isEmpty {
            let ext = URL(fileURLWithPath: diskImagePath).pathExtension.lowercased()
            if ext == "iso" {
                argv += [
                    "-drive", "if=none,id=cdrom,format=raw,readonly=on,file=\(diskImagePath)",
                    "-device", "usb-storage,drive=cdrom"
                ]
            } else {
                let fmt = ext == "qcow2" ? "qcow2" : "raw"
                argv += [
                    "-drive", "if=none,id=hd0,format=\(fmt),file=\(diskImagePath)",
                    "-device", "virtio-blk-pci,drive=hd0"
                ]
            }
        }
        let extra = customQEMUArgs.split(whereSeparator: \.isWhitespace).map(String.init)
        argv.append(contentsOf: extra)
        return argv
    }

    var qemuCommandPreview: String {
        buildQEMUArguments().joined(separator: " ")
    }
}

// MARK: - QEMUEngine (Real dlopen / dlsym Dynamic QEMU Launcher + QMP)

@Observable
@MainActor
final class QEMUEngine {
    enum State: Equatable {
        case idle
        case loading(String)
        case running
        case failed(String)
        case stopped
    }

    private(set) var state: State = .idle
    private(set) var loadedDylibPath: String?
    private(set) var lastCommandLine: String = ""
    private(set) var diagnostics: [String] = []

    let spicePort: UInt16 = 5930
    let qmpPort: UInt16 = 4444
    private var dylibHandle: UnsafeMutableRawPointer?
    private var qmpConnection: NWConnection?

    func start(vm: VirtualMachine) {
        stop()
        let args = vm.buildQEMUArguments(spicePort: spicePort, qmpPort: qmpPort)
        lastCommandLine = args.joined(separator: " ")
        diagnostics = ["[QEMU] Preparing \(vm.architecture.dylibName)"]
        state = .loading("Locating \(vm.architecture.dylibName)...")

        guard let (handle, path) = openQEMUDylib(named: vm.architecture.dylibName) else {
            let err = String(cString: dlerror() ?? UnsafePointer(bitPattern: 0)!)
            let msg = "Missing \(vm.architecture.dylibName) in Frameworks/. Bundle QEMU + CocoaSpice dylibs to boot \(vm.diskFileName)."
            diagnostics.append("[QEMU] dlopen failed: \(err.isEmpty ? "not found" : err)")
            state = .failed(msg)
            return
        }

        dylibHandle = handle
        loadedDylibPath = path
        diagnostics.append("[QEMU] Loaded \(URL(fileURLWithPath: path).lastPathComponent)")

        guard let initSym = dlsym(handle, "qemu_init"),
              let loopSym = dlsym(handle, "qemu_main_loop"),
              let cleanupSym = dlsym(handle, "qemu_cleanup") else {
            state = .failed("Missing qemu_init / qemu_main_loop / qemu_cleanup symbols in \(vm.architecture.dylibName).")
            dlclose(handle)
            dylibHandle = nil
            return
        }

        state = .running
        diagnostics.append("[QEMU] Executing \(args.count) CLI arguments on 8MB thread")

        let initAddr = UInt(bitPattern: initSym)
        let loopAddr = UInt(bitPattern: loopSym)
        let cleanupAddr = UInt(bitPattern: cleanupSym)

        let thread = Thread { [weak self] in
            typealias QemuInitFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
            typealias QemuMainLoopFn = @convention(c) () -> Int32
            typealias QemuCleanupFn = @convention(c) () -> Void

            let qemuInit = unsafeBitCast(UnsafeMutableRawPointer(bitPattern: initAddr), to: QemuInitFn.self)
            let qemuMainLoop = unsafeBitCast(UnsafeMutableRawPointer(bitPattern: loopAddr), to: QemuMainLoopFn.self)
            let qemuCleanup = unsafeBitCast(UnsafeMutableRawPointer(bitPattern: cleanupAddr), to: QemuCleanupFn.self)

            var cStrings: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
            cStrings.append(nil)
            defer { cStrings.forEach { if let p = $0 { free(p) } } }

            cStrings.withUnsafeMutableBufferPointer { buf in
                qemuInit(Int32(args.count), buf.baseAddress)
            }
            _ = qemuMainLoop()
            qemuCleanup()

            Task { @MainActor [weak self] in
                self?.state = .stopped
                self?.diagnostics.append("[QEMU] Main loop exited cleanly")
            }
        }
        thread.name = "com.nexusvm.qemu.main"
        thread.stackSize = 8 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func sendQMP(command: String, arguments: [String: Any]? = nil) {
        let conn = qmpConnection ?? NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: qmpPort)!,
            using: .tcp
        )
        if qmpConnection == nil {
            qmpConnection = conn
            conn.start(queue: .global(qos: .userInitiated))
            if let capsData = "{\"execute\":\"qmp_capabilities\"}\n".data(using: .utf8) {
                conn.send(content: capsData, completion: .contentProcessed { _ in })
            }
        }
        var payload: [String: Any] = ["execute": command]
        if let arguments { payload["arguments"] = arguments }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var json = String(data: data, encoding: .utf8) else { return }
        json.append("\n")
        conn.send(content: json.data(using: .utf8), completion: .contentProcessed { _ in })
        diagnostics.append("[QMP] -> \(command)")
    }

    func stop() {
        if case .running = state { sendQMP(command: "quit") }
        qmpConnection?.cancel()
        qmpConnection = nil
        if let handle = dylibHandle {
            dlclose(handle)
            dylibHandle = nil
        }
        state = .stopped
    }

    private func openQEMUDylib(named name: String) -> (UnsafeMutableRawPointer, String)? {
        var candidates: [String] = []
        if let fw = Bundle.main.privateFrameworksPath {
            candidates.append("\(fw)/\(name)")
            candidates.append("\(fw)/QEMU.framework/\(name)")
        }
        if let res = Bundle.main.resourcePath {
            candidates.append("\(res)/Frameworks/\(name)")
        }
        candidates.append("@rpath/\(name)")
        candidates.append(name)

        for path in candidates {
            if let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                return (h, path)
            }
        }
        return nil
    }
}

// MARK: - Real SPICE Socket + CocoaSpice Dynamic Bridge + Framebuffer Canvas

@Observable
@MainActor
final class SPICESessionController {
    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting SPICE 127.0.0.1:5930"
        case connected = "SPICE Active"
        case cocoaSpice = "CocoaSpice Active"
        case waitingForDisplay = "Waiting for QEMU Framebuffer"
    }

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var guestWidth: Int = 1280
    private(set) var guestHeight: Int = 800
    private(set) var currentFrame: CGImage?
    private(set) var pointerNormalized: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private(set) var packetsReceived: Int = 0

    private let transport = SPICESocketTransport()
    private var cocoaConnectionObj: NSObject?

    func connect(port: UInt16 = 5930) {
        disconnect()
        if attachCocoaSpiceIfPresent(port: port) {
            connectionState = .cocoaSpice
            return
        }
        connectionState = .connecting
        transport.connect(port: port) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    func disconnect() {
        transport.disconnect()
        cocoaConnectionObj = nil
        connectionState = .disconnected
    }

    func sendPointer(normalizedPoint: CGPoint, buttonsMask: UInt8) {
        let x = max(0, min(1, normalizedPoint.x))
        let y = max(0, min(1, normalizedPoint.y))
        pointerNormalized = CGPoint(x: x, y: y)
        let guestX = UInt32(x * Double(max(1, guestWidth - 1)))
        let guestY = UInt32(y * Double(max(1, guestHeight - 1)))
        transport.sendMousePosition(x: guestX, y: guestY, buttonsMask: buttonsMask)

        if let obj = cocoaConnectionObj {
            let sel = NSSelectorFromString("sendMousePosition:buttons:")
            if obj.responds(to: sel) {
                _ = obj.perform(sel, with: NSValue(cgPoint: CGPoint(x: Int(guestX), y: Int(guestY))), with: NSNumber(value: buttonsMask))
            }
        }
    }

    func sendMouseClick(normalizedPoint: CGPoint, button: UInt8 = 1) {
        sendPointer(normalizedPoint: normalizedPoint, buttonsMask: button)
        transport.sendMouseButton(press: true, button: button)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(45))
            self.transport.sendMouseButton(press: false, button: button)
            self.sendPointer(normalizedPoint: normalizedPoint, buttonsMask: 0)
        }
    }

    func sendKeyScancode(_ scancode: UInt32, pressed: Bool = true) {
        transport.sendKeyScancode(scancode, pressed: pressed)
    }

    func sendTextInput(_ text: String) {
        for scalar in text.unicodeScalars {
            if let code = Self.scancode(for: scalar) {
                if Self.needsShift(scalar) { transport.sendKeyScancode(0x2A, pressed: true) }
                transport.sendKeyScancode(code, pressed: true)
                transport.sendKeyScancode(code, pressed: false)
                if Self.needsShift(scalar) { transport.sendKeyScancode(0x2A, pressed: false) }
            }
        }
    }

    func sendCtrlAltDel() {
        let seq: [UInt32] = [0x1D, 0x38, 0xE053]
        for k in seq { transport.sendKeyScancode(k, pressed: true) }
        for k in seq.reversed() { transport.sendKeyScancode(k, pressed: false) }
    }

    private func handle(_ event: SPICESocketTransport.Event) {
        switch event {
        case .connected:
            connectionState = .connected
        case .waiting:
            connectionState = .waitingForDisplay
        case .frame(let image, let w, let h):
            guestWidth = w
            guestHeight = h
            currentFrame = image
            packetsReceived += 1
            connectionState = .connected
        case .packetAck:
            packetsReceived += 1
        }
    }

    private func attachCocoaSpiceIfPresent(port: UInt16) -> Bool {
        if let fw = Bundle.main.privateFrameworksPath {
            _ = dlopen("\(fw)/CocoaSpice.framework/CocoaSpice", RTLD_NOW | RTLD_LOCAL)
            _ = dlopen("\(fw)/libCocoaSpice.dylib", RTLD_NOW | RTLD_LOCAL)
        }
        guard let connCls = NSClassFromString("CSConnection") as? NSObject.Type else { return false }
        let conn = connCls.init()
        let hostSel = NSSelectorFromString("setHost:")
        let portSel = NSSelectorFromString("setPort:")
        let connectSel = NSSelectorFromString("connect")
        if conn.responds(to: hostSel) { _ = conn.perform(hostSel, with: "127.0.0.1") }
        if conn.responds(to: portSel) { _ = conn.perform(portSel, with: "\(port)") }
        if conn.responds(to: connectSel) { _ = conn.perform(connectSel) }
        cocoaConnectionObj = conn
        return true
    }

    private static func needsShift(_ s: UnicodeScalar) -> Bool {
        CharacterSet.uppercaseLetters.contains(s) || "!@#$%^&*()_+{}|:\"<>?~".unicodeScalars.contains(s)
    }

    private static func scancode(for scalar: UnicodeScalar) -> UInt32? {
        let map: [Character: UInt32] = [
            "1": 0x02, "!": 0x02, "2": 0x03, "@": 0x03, "3": 0x04, "#": 0x04, "4": 0x05, "$": 0x05,
            "5": 0x06, "%": 0x06, "6": 0x07, "^": 0x07, "7": 0x08, "&": 0x08, "8": 0x09, "*": 0x09,
            "9": 0x0A, "(": 0x0A, "0": 0x0B, ")": 0x0B, "-": 0x0C, "_": 0x0C, "=": 0x0D, "+": 0x0D,
            "\u{08}": 0x0E, "\t": 0x0F,
            "q": 0x10, "w": 0x11, "e": 0x12, "r": 0x13, "t": 0x14, "y": 0x15, "u": 0x16, "i": 0x17, "o": 0x18, "p": 0x19,
            "[": 0x1A, "{": 0x1A, "]": 0x1B, "}": 0x1B, "\n": 0x1C, "\r": 0x1C,
            "a": 0x1E, "s": 0x1F, "d": 0x20, "f": 0x21, "g": 0x22, "h": 0x23, "j": 0x24, "k": 0x25, "l": 0x26,
            ";": 0x27, ":": 0x27, "'": 0x28, "\"": 0x28, "`": 0x29, "~": 0x29, "\\": 0x2B, "|": 0x2B,
            "z": 0x2C, "x": 0x2D, "c": 0x2E, "v": 0x2F, "b": 0x30, "n": 0x31, "m": 0x32,
            ",": 0x33, "<": 0x33, ".": 0x34, ">": 0x34, "/": 0x35, "?": 0x35, " ": 0x39
        ]
        let lower = Character(String(scalar).lowercased())
        return map[lower]
    }
}

final class SPICESocketTransport: @unchecked Sendable {
    enum Event: Sendable {
        case connected, waiting, packetAck, frame(CGImage, Int, Int)
    }

    private let queue = DispatchQueue(label: "com.nexusvm.spice.tcp", qos: .userInteractive)
    private var mainConn: NWConnection?
    private var displayConn: NWConnection?
    private var inputsConn: NWConnection?
    private var sessionID: UInt32 = 0
    private var retryCount = 0
    private var active = false
    private var callback: (@Sendable (Event) -> Void)?

    func connect(port: UInt16, onEvent: @escaping @Sendable (Event) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.active = true
            self.retryCount = 0
            self.callback = onEvent
            self.openChannel(type: 1, port: port)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.active = false
            self?.mainConn?.cancel(); self?.mainConn = nil
            self?.displayConn?.cancel(); self?.displayConn = nil
            self?.inputsConn?.cancel(); self?.inputsConn = nil
        }
    }

    func sendMousePosition(x: UInt32, y: UInt32, buttonsMask: UInt8) {
        queue.async { [weak self] in
            guard let conn = self?.inputsConn else { return }
            var body = Data()
            body.appendLE(x)
            body.appendLE(y)
            body.append(buttonsMask)
            body.append(0)
            self?.sendSPICEMessage(conn: conn, type: 103, payload: body)
        }
    }

    func sendMouseButton(press: Bool, button: UInt8) {
        queue.async { [weak self] in
            guard let conn = self?.inputsConn else { return }
            var body = Data([button, 0])
            body.appendLE(UInt16(0))
            self?.sendSPICEMessage(conn: conn, type: press ? 104 : 105, payload: body)
        }
    }

    func sendKeyScancode(_ scancode: UInt32, pressed: Bool) {
        queue.async { [weak self] in
            guard let conn = self?.inputsConn else { return }
            let makeCode = pressed ? scancode : (scancode | 0x80)
            var body = Data()
            body.appendLE(makeCode)
            self?.sendSPICEMessage(conn: conn, type: 101, payload: body)
        }
    }

    private func openChannel(type channelType: UInt8, port: UInt16) {
        guard active else { return }
        let conn = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        if channelType == 1 { mainConn = conn }
        else if channelType == 2 { displayConn = conn }
        else if channelType == 3 { inputsConn = conn }

        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.sendRedLinkMess(conn: conn, channelType: channelType)
                if channelType == 1 {
                    self.callback?(.connected)
                    self.openChannel(type: 2, port: port)
                    self.openChannel(type: 3, port: port)
                }
                self.receiveLoop(conn: conn, channelType: channelType)
            case .failed, .waiting:
                if channelType == 1 && self.active && self.retryCount < 8 {
                    self.retryCount += 1
                    self.callback?(.waiting)
                    conn.cancel()
                    self.queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.openChannel(type: 1, port: port)
                    }
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func sendRedLinkMess(conn: NWConnection, channelType: UInt8) {
        // SpiceLinkHeader ("REDQ", major=2, minor=2, size=22) + SpiceLinkMess (18B + 4B common cap)
        var packet = Data([0x52, 0x45, 0x44, 0x51])
        packet.appendLE(UInt32(2))
        packet.appendLE(UInt32(2))
        packet.appendLE(UInt32(22))
        packet.appendLE(sessionID)
        packet.append(channelType)
        packet.append(0)
        packet.appendLE(UInt32(1))
        packet.appendLE(UInt32(0))
        packet.appendLE(UInt32(18))
        packet.appendLE(UInt32(0x0B)) // AuthSelection | SemiSeamless | MiniHeader
        conn.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func sendSPICEMessage(conn: NWConnection, type msgType: UInt16, payload: Data) {
        var frame = Data()
        frame.appendLE(msgType)
        frame.appendLE(UInt32(payload.count))
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receiveLoop(conn: NWConnection, channelType: UInt8) {
        conn.receive(minimumIncompleteLength: 6, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if channelType == 1 && data.count >= 20 && data[0] == 0x52 && data[1] == 0x45 {
                    let ackOk = Data([0, 0, 0, 0])
                    conn.send(content: ackOk, completion: .contentProcessed { _ in })
                } else if channelType == 2, let img = self.tryDecodeSurface(data: data) {
                    self.callback?(.frame(img, img.width, img.height))
                } else {
                    self.callback?(.packetAck)
                }
            }
            if !isComplete && error == nil && self.active {
                self.receiveLoop(conn: conn, channelType: channelType)
            }
        }
    }

    private func tryDecodeSurface(data: Data) -> CGImage? {
        // Parses raw 32-bit BGRA surface payload when present
        guard data.count >= 24 else { return nil }
        let width = Int(data.readUInt32LE(at: 6))
        let height = Int(data.readUInt32LE(at: 10))
        guard width >= 320 && width <= 4096 && height >= 200 && height <= 2560 else { return nil }
        let expected = width * height * 4
        guard data.count >= 24 + expected else { return nil }
        let pixelSlice = data.subdata(in: 24..<(24 + expected))
        guard let provider = CGDataProvider(data: pixelSlice as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
    }
}

// MARK: - Live Framebuffer + USB-Tablet Touch + Hardware Keyboard UIViewRepresentable

struct SPICEDisplayView: UIViewRepresentable {
    let session: SPICESessionController
    let vm: VirtualMachine
    let engineState: QEMUEngine.State
    let showKeyboard: Bool
    let onTapPointer: (CGPoint) -> Void
    let onDragPointer: (CGPoint, Bool) -> Void
    let onTypeText: (String) -> Void
    let onDeleteBackward: () -> Void

    func makeUIView(context: Context) -> SPICECanvasUIView {
        let view = SPICECanvasUIView()
        view.onTap = onTapPointer
        view.onDrag = onDragPointer
        view.onInsertText = onTypeText
        view.onBackspace = onDeleteBackward
        return view
    }

    func updateUIView(_ uiView: SPICECanvasUIView, context: Context) {
        uiView.updateFrame(
            image: session.currentFrame,
            cursor: session.pointerNormalized,
            vmName: vm.name,
            isoName: vm.diskFileName,
            statusText: overlayStatusText
        )
        if showKeyboard && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !showKeyboard && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    private var overlayStatusText: String {
        switch engineState {
        case .failed(let msg): return msg
        case .loading(let msg): return msg
        case .stopped: return "QEMU VM Stopped"
        case .idle, .running:
            return session.currentFrame == nil
                ? "\(session.connectionState.rawValue) · Waiting for virtio-gpu-pci scanout..."
                : ""
        }
    }
}

final class SPICECanvasUIView: UIView, UIKeyInput {
    var onTap: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint, Bool) -> Void)?
    var onInsertText: ((String) -> Void)?
    var onBackspace: (() -> Void)?

    private let imageLayer = CALayer()
    private let cursorLayer = CAShapeLayer()
    private let statusLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let metalDevice = MTLCreateSystemDefaultDevice()

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1.0)
        isMultipleTouchEnabled = false

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .linear
        layer.addSublayer(imageLayer)

        let path = UIBezierPath(ovalIn: CGRect(x: -5, y: -5, width: 10, height: 10))
        cursorLayer.path = path.cgPath
        cursorLayer.fillColor = UIColor(red: 0, green: 0.9, blue: 1, alpha: 0.85).cgColor
        cursorLayer.strokeColor = UIColor.white.cgColor
        cursorLayer.lineWidth = 1.5
        layer.addSublayer(cursorLayer)

        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = UIColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        addSubview(statusLabel)

        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 0.65, alpha: 1.0)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageLayer.frame = bounds
        statusLabel.frame = CGRect(x: 24, y: bounds.midY - 40, width: max(0, bounds.width - 48), height: 48)
        subtitleLabel.frame = CGRect(x: 24, y: bounds.midY + 14, width: max(0, bounds.width - 48), height: 64)
    }

    func updateFrame(image: CGImage?, cursor: CGPoint, vmName: String, isoName: String, statusText: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        let targetFrame = aspectFitRect(imageSize: image.map { CGSize(width: $0.width, height: $0.height) } ?? bounds.size, in: bounds)
        cursorLayer.position = CGPoint(
            x: targetFrame.minX + cursor.x * targetFrame.width,
            y: targetFrame.minY + cursor.y * targetFrame.height
        )
        CATransaction.commit()

        let hasFrame = image != nil
        statusLabel.isHidden = hasFrame
        subtitleLabel.isHidden = hasFrame
        if !hasFrame {
            statusLabel.text = "\(vmName) · \(isoName)"
            let gpuTag = metalDevice != nil ? "Metal GPU Ready" : "CoreGraphics Canvas"
            subtitleLabel.text = "\(statusText)\n[\(gpuTag) · SPICE 127.0.0.1:5930]"
        }
    }

    func insertText(_ text: String) { onInsertText?(text) }
    func deleteBackward() { onBackspace?() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = normalizedTouch(touches.first) else { return }
        onDrag?(pt, true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = normalizedTouch(touches.first) else { return }
        onDrag?(pt, true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = normalizedTouch(touches.first) else { return }
        onDrag?(pt, false)
        onTap?(pt)
    }

    private func normalizedTouch(_ touch: UITouch?) -> CGPoint? {
        guard let touch, bounds.width > 0, bounds.height > 0 else { return nil }
        let p = touch.location(in: self)
        let imgSize = (imageLayer.contents as! CGImage?).map { CGSize(width: $0.width, height: $0.height) } ?? bounds.size
        let rect = aspectFitRect(imageSize: imgSize, in: bounds)
        let nx = max(0, min(1, (p.x - rect.minX) / max(1, rect.width)))
        let ny = max(0, min(1, (p.y - rect.minY) / max(1, rect.height)))
        return CGPoint(x: nx, y: ny)
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return container }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: container.midX - w / 2, y: container.midY - h / 2, width: w, height: h)
    }
}

// MARK: - Live StikDebug JIT Detector

@Observable
@MainActor
final class JITDetector {
    private(set) var isJITActive = false
    private(set) var rawFlags: UInt32 = 0
    private(set) var checkCount = 0
    private(set) var pid: pid_t = getpid()

    init() { refresh(haptic: false) }
    var hexFlags: String { String(format: "0x%08X", rawFlags) }

    func refresh(haptic: Bool = true) {
        pid = getpid()
        var flags: UInt32 = 0
        let rc = withUnsafeMutablePointer(to: &flags) {
            csops(pid, CSFlags.opsStatus, UnsafeMutableRawPointer($0), MemoryLayout<UInt32>.size)
        }
        rawFlags = rc == 0 ? flags : 0
        isJITActive = rc == 0 && (flags & CSFlags.debugged) != 0
        checkCount += 1
        if haptic { UIImpactFeedbackGenerator(style: isJITActive ? .medium : .light).impactOccurred() }
    }
}

// MARK: - App Settings & VM Store

@Observable
@MainActor
final class AppSettings {
    var autoPollJIT: Bool { didSet { UserDefaults.standard.set(autoPollJIT, forKey: "n.poll") } }
    var keepScreenAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenAwake, forKey: "n.awake")
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        }
    }
    var hapticsEnabled: Bool { didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "n.haptic") } }
    var consoleFontSize: Double { didSet { UserDefaults.standard.set(consoleFontSize, forKey: "n.font") } }
    var defaultRenderer: GraphicsRenderer { didSet { UserDefaults.standard.set(defaultRenderer.rawValue, forKey: "n.rend") } }

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "n.poll") == nil { d.set(true, forKey: "n.poll") }
        if d.object(forKey: "n.awake") == nil { d.set(true, forKey: "n.awake") }
        if d.object(forKey: "n.haptic") == nil { d.set(true, forKey: "n.haptic") }
        if d.object(forKey: "n.font") == nil { d.set(12.0, forKey: "n.font") }
        autoPollJIT = d.bool(forKey: "n.poll")
        keepScreenAwake = d.bool(forKey: "n.awake")
        hapticsEnabled = d.bool(forKey: "n.haptic")
        consoleFontSize = max(10, min(18, d.double(forKey: "n.font")))
        defaultRenderer = GraphicsRenderer(rawValue: d.string(forKey: "n.rend") ?? "") ?? .metal
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
    }

    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        if hapticsEnabled { UIImpactFeedbackGenerator(style: style).impactOccurred() }
    }
}

@Observable
@MainActor
final class VMStore {
    private(set) var machines: [VirtualMachine] = []
    private let fm = FileManager.default
    private var docsURL: URL { fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory }
    private var storeURL: URL { docsURL.appendingPathComponent("NexusVM_VMs.json") }
    private var disksURL: URL { docsURL.appendingPathComponent("DiskImages", isDirectory: true) }

    init() {
        try? fm.createDirectory(at: disksURL, withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard fm.fileExists(atPath: storeURL.path), let data = try? Data(contentsOf: storeURL) else {
            machines = Self.defaults()
            save()
            return
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        machines = (try? dec.decode([VirtualMachine].self, from: data)) ?? []
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(machines) { try? data.write(to: storeURL, options: [.atomic]) }
    }

    func add(_ vm: VirtualMachine) { machines.insert(vm, at: 0); save() }
    func update(_ vm: VirtualMachine) {
        if let i = machines.firstIndex(where: { $0.id == vm.id }) { machines[i] = vm; save() }
    }
    func delete(id: UUID) { machines.removeAll { $0.id == id }; save() }
    func setStatus(_ status: VMStatus, for id: UUID) {
        if let i = machines.firstIndex(where: { $0.id == id }) {
            machines[i].status = status
            if status == .running { machines[i].lastBootedAt = Date() }
            save()
        }
    }

    func importDisk(from src: URL) throws -> String {
        try fm.createDirectory(at: disksURL, withIntermediateDirectories: true)
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        var dst = disksURL.appendingPathComponent(src.lastPathComponent)
        if fm.fileExists(atPath: dst.path) {
            let base = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension
            let stamp = Int(Date().timeIntervalSince1970)
            dst = disksURL.appendingPathComponent(ext.isEmpty ? "\(base)-\(stamp)" : "\(base)-\(stamp).\(ext)")
        }
        try fm.copyItem(at: src, to: dst)
        return dst.path
    }

    var cachedDiskCount: Int { (try? fm.contentsOfDirectory(atPath: disksURL.path).count) ?? 0 }
    func purgeUnusedDisks() -> Int {
        let used = Set(machines.map(\.diskImagePath).filter { !$0.isEmpty })
        guard let files = try? fm.contentsOfDirectory(at: disksURL, includingPropertiesForKeys: nil) else { return 0 }
        return files.filter { !used.contains($0.path) }.reduce(0) { $0 + ((try? fm.removeItem(at: $1)) != nil ? 1 : 0) }
    }

    var totalRAMMB: Int { machines.reduce(0) { $0 + $1.ramMB } }
    var activeCount: Int { machines.filter { $0.status == .running }.count }

    private static func defaults() -> [VirtualMachine] {
        [
            VirtualMachine(name: "Fedora 45 Workstation", osPreset: .linux, mode: .virtualize, architecture: .arm64, cpuCores: 4, ramMB: 4096, storageGB: 32, renderer: .metal, networkMode: .nat, diskImagePath: "Fedora-Workstation-Live-45-1.4.aarch64.iso"),
            VirtualMachine(name: "Windows 11 x64", osPreset: .windows, mode: .emulate, architecture: .x86_64, cpuCores: 4, ramMB: 4096, storageGB: 64, renderer: .angle, networkMode: .nat, diskImagePath: "win11_24h2_x64.qcow2")
        ]
    }
}

// MARK: - App Entry Point

@main
struct NexusVMApp: App {
    @State private var store = VMStore()
    @State private var jit = JITDetector()
    @State private var settings = AppSettings()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(jit)
                .environment(settings)
                .preferredColorScheme(.dark)
                .onChange(of: phase) { _, new in if new == .active { jit.refresh(haptic: false) } }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        if settings.autoPollJIT { jit.refresh(haptic: false) }
                    }
                }
        }
    }
}

enum NexusTab: String, CaseIterable, Identifiable {
    case machines = "Machines", create = "Create", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .machines: return "cpu.fill"
        case .create: return "plus.square.fill"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct RootTabView: View {
    @Environment(VMStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var tab: NexusTab = .machines
    @State private var runningVM: VirtualMachine?
    @State private var inspectVM: VirtualMachine?

    var body: some View {
        ZStack(alignment: .bottom) {
            NexusTheme.bg.ignoresSafeArea()
            Group {
                switch tab {
                case .machines:
                    MachinesDashboardView(
                        onLaunch: { vm in
                            store.setStatus(.running, for: vm.id)
                            runningVM = store.machines.first { $0.id == vm.id } ?? vm
                        },
                        onInspect: { inspectVM = $0 }
                    )
                case .create:
                    CreateVMWizardView { vm in store.add(vm); tab = .machines }
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 6) {
                ForEach(NexusTab.allCases) { item in
                    let active = tab == item
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { tab = item }
                        settings.impact(.light)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.icon).font(.system(size: 14, weight: .semibold))
                            Text(item.rawValue).font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(active ? NexusTheme.bg : NexusTheme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(active ? NexusTheme.cyan : .clear))
                    }.buttonStyle(.plain)
                }
            }
            .padding(6).background(.ultraThinMaterial).background(NexusTheme.card.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(NexusTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
            .padding(.horizontal, 20).padding(.bottom, 10)
        }
        .sheet(item: $inspectVM) { vm in
            VMInspectorView(vm: vm) { launched in
                inspectVM = nil
                store.setStatus(.running, for: launched.id)
                runningVM = store.machines.first { $0.id == launched.id } ?? launched
            }
        }
        .fullScreenCover(item: $runningVM) { vm in
            ActiveVMDisplayRunnerView(vm: vm)
        }
    }
}

struct JITStatusPill: View {
    @Environment(JITDetector.self) private var jit
    @State private var showInfo = false

    var body: some View {
        let tint = jit.isJITActive ? NexusTheme.cyan : NexusTheme.amber
        HStack(spacing: 6) {
            Button { withAnimation { jit.refresh(haptic: true) } } label: {
                HStack(spacing: 7) {
                    Circle().fill(tint).frame(width: 8, height: 8).shadow(color: tint.opacity(0.8), radius: 4)
                    Text(jit.isJITActive ? "JIT Active" : "Waiting for StikDebug")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold)).foregroundStyle(NexusTheme.textSecondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7).background(tint.opacity(0.12))
                .clipShape(Capsule()).overlay(Capsule().strokeBorder(tint.opacity(0.38), lineWidth: 1))
            }.buttonStyle(.plain)

            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.system(size: 15)).foregroundStyle(NexusTheme.textSecondary)
            }.buttonStyle(.plain)
        }
        .alert("csops() Kernel Status", isPresented: $showInfo) {
            Button("Refresh") { jit.refresh(haptic: true) }
            Button("OK", role: .cancel) {}
        } message: {
            Text("PID: \(jit.pid)\nFlags: \(jit.hexFlags)\nCS_DEBUGGED (0x10000000): \(jit.isJITActive ? "SET" : "UNSET")")
        }
    }
}

// MARK: - Machines Dashboard

struct MachinesDashboardView: View {
    @Environment(VMStore.self) private var store
    @Environment(AppSettings.self) private var settings
    let onLaunch: (VirtualMachine) -> Void
    let onInspect: (VirtualMachine) -> Void
    @State private var grid = true
    @State private var query = ""

    private var filtered: [VirtualMachine] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? store.machines : store.machines.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.architecture.rawValue.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Image(systemName: "cube.transparent.fill").foregroundStyle(NexusTheme.cyan)
                                Text("NexusVM").font(.system(size: 23, weight: .bold, design: .rounded))
                            }
                            Text("QEMU + SPICE Graphical Runner").font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary)
                        }
                        Spacer()
                        JITStatusPill()
                    }

                    HStack(spacing: 10) {
                        statTile("MACHINES", "\(store.machines.count)", NexusTheme.textPrimary)
                        statTile("ACTIVE", "\(store.activeCount)", store.activeCount > 0 ? NexusTheme.emerald : NexusTheme.textSecondary)
                        statTile("POOL RAM", String(format: "%.1fG", Double(store.totalRAMMB) / 1024.0), NexusTheme.cyan)
                    }

                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(NexusTheme.textMuted)
                            TextField("Filter VMs...", text: $query).font(.system(size: 14)).autocorrectionDisabled()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9).nexusCard(radius: 12)

                        Button { withAnimation { grid.toggle() }; settings.impact(.light) } label: {
                            Image(systemName: grid ? "list.bullet" : "square.grid.2x2")
                                .foregroundStyle(NexusTheme.cyan).frame(width: 40, height: 38).nexusCard(radius: 12)
                        }.buttonStyle(.plain)
                    }

                    if filtered.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "server.rack").font(.system(size: 32)).foregroundStyle(NexusTheme.textMuted)
                            Text("No Virtual Machines").font(.headline)
                        }.frame(maxWidth: .infinity).padding(.vertical, 36).nexusCard()
                    } else if grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                            ForEach(filtered) { vm in vmCard(vm) }
                        }
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filtered) { vm in vmRow(vm) }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 100)
            }
            .background(NexusTheme.bg)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func statTile(_ title: String, _ val: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(NexusTheme.textMuted)
            Text(val).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(tint)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).nexusCard(radius: 12)
    }

    private func statusBadge(_ status: VMStatus) -> some View {
        HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.rawValue.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(status.color)
        }.padding(.horizontal, 7).padding(.vertical, 3).background(status.color.opacity(0.14)).clipShape(Capsule())
    }

    private func chip(_ text: String, _ tint: Color = NexusTheme.textSecondary) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 3).nexusCard(elevated: true, radius: 6)
    }

    private func vmCard(_ vm: VirtualMachine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: vm.osPreset.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(vm.osPreset.tint)
                    .frame(width: 34, height: 34).background(vm.osPreset.tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer()
                statusBadge(vm.status)
            }
            Text(vm.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(vm.diskFileName).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.textMuted).lineLimit(1)
            HStack(spacing: 5) { chip(vm.architecture.rawValue, NexusTheme.cyan); chip("\(vm.cpuCores)C"); chip(vm.formattedRAM) }
            Divider().overlay(NexusTheme.border)
            HStack(spacing: 8) {
                Button { togglePlay(vm) } label: {
                    Image(systemName: vm.status == .running ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(NexusTheme.bg)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(vm.status == .running ? NexusTheme.amber : NexusTheme.cyan)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }.buttonStyle(.plain)
                if vm.status != .stopped {
                    Button { store.setStatus(.stopped, for: vm.id) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(NexusTheme.crimson)
                            .frame(width: 32, height: 32).background(NexusTheme.crimson.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }.buttonStyle(.plain)
                }
                Button { onLaunch(vm) } label: {
                    Image(systemName: "display").font(.system(size: 13)).frame(width: 32, height: 32).nexusCard(elevated: true, radius: 9)
                }.buttonStyle(.plain)
            }
        }
        .padding(12).nexusCard(borderColor: vm.status == .running ? NexusTheme.emerald.opacity(0.45) : NexusTheme.border)
        .contentShape(Rectangle()).onTapGesture { onInspect(vm) }
        .contextMenu {
            Button("Boot Desktop", systemImage: "display") { onLaunch(vm) }
            Button("Inspect", systemImage: "wrench") { onInspect(vm) }
            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(id: vm.id) }
        }
    }

    private func vmRow(_ vm: VirtualMachine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: vm.osPreset.symbol).foregroundStyle(vm.osPreset.tint)
                .frame(width: 38, height: 38).background(vm.osPreset.tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) { Text(vm.name).font(.system(size: 15, weight: .semibold)).lineLimit(1); statusBadge(vm.status) }
                HStack(spacing: 5) { chip(vm.architecture.rawValue, NexusTheme.cyan); chip("\(vm.cpuCores)C"); chip(vm.formattedRAM) }
            }
            Spacer()
            Button { togglePlay(vm) } label: {
                Image(systemName: vm.status == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(NexusTheme.bg)
                    .frame(width: 32, height: 32).background(vm.status == .running ? NexusTheme.amber : NexusTheme.cyan)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }.buttonStyle(.plain)
        }
        .padding(12).nexusCard(borderColor: vm.status == .running ? NexusTheme.emerald.opacity(0.45) : NexusTheme.border)
        .contentShape(Rectangle()).onTapGesture { onInspect(vm) }
    }

    private func togglePlay(_ vm: VirtualMachine) {
        settings.impact(.medium)
        if vm.status == .running { store.setStatus(.paused, for: vm.id) } else { onLaunch(vm) }
    }
}

// MARK: - Create VM Wizard

struct CreateVMWizardView: View {
    @Environment(VMStore.self) private var store
    @Environment(AppSettings.self) private var settings
    let onCreate: (VirtualMachine) -> Void

    @State private var step = 0
    @State private var name = "Fedora Workstation"
    @State private var osPreset: OSPreset = .linux
    @State private var mode: ExecutionMode = .virtualize
    @State private var arch: CPUArchitecture = .arm64
    @State private var cores = 4
    @State private var ramMB = 4096
    @State private var storageGB = 32
    @State private var renderer: GraphicsRenderer = .metal
    @State private var network: NetworkMode = .nat
    @State private var diskPath = ""
    @State private var extraArgs = ""
    @State private var showImporter = false
    @State private var importNote: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Create Virtual Machine").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("STEP \(step + 1) OF 3").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(NexusTheme.cyan)
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { i in Capsule().fill(i <= step ? NexusTheme.cyan : NexusTheme.border).frame(height: 4) }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if step == 0 { stepOne } else if step == 1 { stepTwo } else { stepThree }
                    }.padding(.horizontal, 16).padding(.bottom, 140)
                }
            }
            .background(NexusTheme.bg).toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    if step > 0 {
                        Button("Back") { withAnimation { step -= 1 }; settings.impact(.light) }
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(NexusTheme.textPrimary)
                            .frame(maxWidth: .infinity).padding(.vertical, 13).nexusCard(elevated: true)
                    }
                    Button(step < 2 ? "Continue" : "Create VM") {
                        if step < 2 { withAnimation { step += 1 }; settings.impact(.light); return }
                        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCreate(VirtualMachine(
                            name: clean.isEmpty ? "\(osPreset.rawValue) VM" : clean,
                            osPreset: osPreset, mode: mode, architecture: arch,
                            cpuCores: cores, ramMB: ramMB, storageGB: storageGB,
                            renderer: renderer, networkMode: network,
                            diskImagePath: diskPath, customQEMUArgs: extraArgs
                        ))
                        settings.impact(.medium)
                    }
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(NexusTheme.bg)
                    .frame(maxWidth: .infinity).padding(.vertical, 13).background(NexusTheme.cyan)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }.padding(.horizontal, 16).padding(.bottom, 84)
            }
            .onAppear { renderer = settings.defaultRenderer }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: UTType.vmDiskTypes, allowsMultipleSelection: false) { res in
                if case .success(let urls) = res, let u = urls.first {
                    do {
                        diskPath = try store.importDisk(from: u)
                        importNote = "Imported \(URL(fileURLWithPath: diskPath).lastPathComponent)"
                    } catch { importNote = "Error: \(error.localizedDescription)" }
                }
            }
        }
    }

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTag("MACHINE NAME")
            TextField("e.g. Fedora 45 ARM64", text: $name).padding(12).nexusCard(radius: 12)
            sectionTag("EXECUTION MODE")
            ForEach(ExecutionMode.allCases) { item in
                Button { mode = item; settings.impact(.light) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.rawValue).font(.system(size: 15, weight: .semibold)).foregroundStyle(NexusTheme.textPrimary)
                            Text(item.subtitle).font(.system(size: 12)).foregroundStyle(NexusTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: mode == item ? "checkmark.circle.fill" : "circle").foregroundStyle(mode == item ? NexusTheme.cyan : NexusTheme.textMuted)
                    }.padding(12).nexusCard(borderColor: mode == item ? NexusTheme.cyan : NexusTheme.border, radius: 12)
                }.buttonStyle(.plain)
            }
            sectionTag("OS PRESET")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(OSPreset.allCases) { p in
                    Button {
                        osPreset = p; mode = p.defaultMode; arch = p.defaultArch; ramMB = p.defaultRAM; storageGB = p.defaultStorage
                        name = "\(p.rawValue) VM"; settings.impact(.light)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: p.symbol).font(.system(size: 18)).foregroundStyle(p.tint)
                            Text(p.rawValue).font(.system(size: 14, weight: .semibold)).foregroundStyle(NexusTheme.textPrimary)
                            Text(p.defaultArch.rawValue).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .nexusCard(borderColor: osPreset == p ? NexusTheme.cyan : NexusTheme.border, radius: 12)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTag("ARCHITECTURE")
            Picker("Arch", selection: $arch) { ForEach(CPUArchitecture.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 8) {
                HStack { sectionTag("CPU CORES"); Spacer(); Text("\(cores) vCPU").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(NexusTheme.cyan) }
                Slider(value: Binding(get: { Double(cores) }, set: { cores = Int($0.rounded()) }), in: 1...8, step: 1).tint(NexusTheme.cyan)
            }.padding(12).nexusCard()
            VStack(alignment: .leading, spacing: 8) {
                HStack { sectionTag("MEMORY"); Spacer(); Text("\(ramMB) MB").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(NexusTheme.cyan) }
                Slider(value: Binding(get: { Double(ramMB) }, set: { ramMB = Int(($0 / 256).rounded()) * 256 }), in: 512...8192, step: 256).tint(NexusTheme.cyan)
            }.padding(12).nexusCard()
            VStack(spacing: 10) {
                HStack { Text("Renderer"); Spacer(); Picker("Renderer", selection: $renderer) { ForEach(GraphicsRenderer.allCases) { Text($0.rawValue).tag($0) } }.tint(NexusTheme.cyan) }
                Divider().overlay(NexusTheme.border)
                HStack { Text("Network"); Spacer(); Picker("Network", selection: $network) { ForEach(NetworkMode.allCases) { Text($0.rawValue).tag($0) } }.tint(NexusTheme.cyan) }
            }.padding(12).nexusCard()
        }
    }

    private var stepThree: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTag("BOOT ISO / DISK IMAGE")
            Button { showImporter = true } label: {
                HStack {
                    Image(systemName: diskPath.isEmpty ? "folder.badge.plus" : "opticaldisc.fill").foregroundStyle(NexusTheme.cyan)
                    Text(diskPath.isEmpty ? "Import .iso / .qcow2 / .img from Files" : URL(fileURLWithPath: diskPath).lastPathComponent)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(NexusTheme.textPrimary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(NexusTheme.textMuted)
                }.padding(14).nexusCard(borderColor: diskPath.isEmpty ? NexusTheme.border : NexusTheme.cyan.opacity(0.6))
            }.buttonStyle(.plain)
            if let importNote { Text(importNote).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.emerald) }
            sectionTag("CUSTOM QEMU FLAGS")
            TextField("Optional extra args", text: $extraArgs).font(.system(size: 13, design: .monospaced)).foregroundStyle(NexusTheme.cyan)
                .autocorrectionDisabled().textInputAutocapitalization(.never).padding(12).nexusCard(radius: 12)
        }
    }
}

// MARK: - Active Graphical QEMU + SPICE VM Runner View

struct ActiveVMDisplayRunnerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(VMStore.self) private var store
    @Environment(JITDetector.self) private var jit
    @Environment(AppSettings.self) private var settings

    @State var vm: VirtualMachine
    @State private var engine = QEMUEngine()
    @State private var spice = SPICESessionController()
    @State private var showKeyboard = false
    @State private var toolbarCollapsed = false
    @State private var showISOImporter = false
    @State private var showHaltConfirm = false
    @State private var showDiagnostics = false
    @State private var zoomScale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topStatusBar

                SPICEDisplayView(
                    session: spice,
                    vm: vm,
                    engineState: engine.state,
                    showKeyboard: showKeyboard,
                    onTapPointer: { pt in
                        spice.sendMouseClick(normalizedPoint: pt, button: 1)
                    },
                    onDragPointer: { pt, down in
                        spice.sendPointer(normalizedPoint: pt, buttonsMask: down ? 1 : 0)
                    },
                    onTypeText: { text in
                        spice.sendTextInput(text)
                    },
                    onDeleteBackward: {
                        spice.sendKeyScancode(0x0E, pressed: true)
                        spice.sendKeyScancode(0x0E, pressed: false)
                    }
                )
                .scaleEffect(zoomScale)
                .gesture(
                    MagnifyGesture().onEnded { v in
                        withAnimation(.spring(response: 0.25)) {
                            zoomScale = min(2.5, max(1.0, zoomScale * v.magnification))
                        }
                    }
                )
            }

            floatingToolbar
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            engine.start(vm: vm)
            spice.connect(port: engine.spicePort)
        }
        .onDisappear {
            spice.disconnect()
            engine.stop()
            store.setStatus(.stopped, for: vm.id)
        }
        .fileImporter(isPresented: $showISOImporter, allowedContentTypes: UTType.vmDiskTypes, allowsMultipleSelection: false) { res in
            if case .success(let urls) = res, let u = urls.first, let path = try? store.importDisk(from: u) {
                vm.diskImagePath = path
                store.update(vm)
                engine.sendQMP(command: "blockdev-change-medium", arguments: ["id": "cdrom", "filename": path, "format": "raw"])
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("CLI: \(engine.lastCommandLine)")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.cyan)
                        Divider().overlay(NexusTheme.border)
                        ForEach(engine.diagnostics, id: \.self) { line in
                            Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary)
                        }
                    }.padding()
                }
                .background(NexusTheme.bg)
                .navigationTitle("QEMU + SPICE Log")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDiagnostics = false } } }
            }.presentationDetents([.medium])
        }
        .confirmationDialog("Force Shutdown \(vm.name)?", isPresented: $showHaltConfirm, titleVisibility: .visible) {
            Button("Force Power Off", role: .destructive) {
                spice.disconnect()
                engine.stop()
                store.setStatus(.stopped, for: vm.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var topStatusBar: some View {
        HStack(spacing: 8) {
            Button {
                spice.disconnect()
                engine.stop()
                store.setStatus(.stopped, for: vm.id)
                dismiss()
            } label: {
                Label("Stop", systemImage: "chevron.left").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6).nexusCard(elevated: true, radius: 9)
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(vm.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Text("\(spice.connectionState.rawValue) · \(spice.guestWidth)x\(spice.guestHeight)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary)
            }

            Spacer()

            Button { showDiagnostics = true } label: {
                Image(systemName: "waveform.path.ecg").font(.system(size: 13)).foregroundStyle(NexusTheme.cyan)
                    .padding(6).nexusCard(elevated: true, radius: 8)
            }.buttonStyle(.plain)

            Text(jit.isJITActive ? "JIT" : "NO JIT")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(jit.isJITActive ? NexusTheme.cyan : NexusTheme.amber)
                .padding(.horizontal, 8).padding(.vertical, 5).nexusCard(radius: 99)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(NexusTheme.bg)
    }

    private var floatingToolbar: some View {
        HStack(spacing: 8) {
            Button { withAnimation { toolbarCollapsed.toggle() }; settings.impact(.light) } label: {
                Image(systemName: toolbarCollapsed ? "chevron.up" : "chevron.down")
                    .foregroundStyle(NexusTheme.cyan).frame(width: 36, height: 36).nexusCard(elevated: true, radius: 10)
            }.buttonStyle(.plain)

            if !toolbarCollapsed {
                toolbarButton("keyboard", "Keys", showKeyboard ? NexusTheme.cyan : NexusTheme.textPrimary) {
                    showKeyboard.toggle()
                    settings.impact(.light)
                }
                toolbarButton("command", "Ctrl+Alt+Del", NexusTheme.amber) {
                    spice.sendCtrlAltDel()
                    settings.impact(.medium)
                }
                toolbarButton("opticaldisc", vm.diskImagePath.isEmpty ? "Mount" : "Eject", NexusTheme.textPrimary) {
                    if vm.diskImagePath.isEmpty {
                        showISOImporter = true
                    } else {
                        engine.sendQMP(command: "eject", arguments: ["id": "cdrom", "force": true])
                        vm.diskImagePath = ""
                        store.update(vm)
                    }
                    settings.impact(.light)
                }
                toolbarButton("power", "Halt", NexusTheme.crimson) {
                    showHaltConfirm = true
                    settings.impact(.medium)
                }
            }
        }
        .padding(8).background(.ultraThinMaterial).background(NexusTheme.card.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(NexusTheme.border, lineWidth: 1))
    }

    private func toolbarButton(_ icon: String, _ title: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .medium, design: .monospaced)).lineLimit(1)
            }
            .foregroundStyle(tint).frame(maxWidth: .infinity).padding(.vertical, 6).nexusCard(elevated: true, radius: 10)
        }.buttonStyle(.plain)
    }
}

// MARK: - VM Inspector & Settings

struct VMInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(VMStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State var vm: VirtualMachine
    let onLaunch: (VirtualMachine) -> Void
    @State private var showPicker = false
    @State private var copied = false
    @State private var confirmDel = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTag("GENERAL")
                    TextField("VM Name", text: $vm.name).padding(12).nexusCard(radius: 12)
                    Picker("Mode", selection: $vm.mode) { ForEach(ExecutionMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    Picker("Arch", selection: $vm.architecture) { ForEach(CPUArchitecture.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)

                    VStack(spacing: 10) {
                        Stepper("CPU Cores: \(vm.cpuCores)", value: $vm.cpuCores, in: 1...8)
                        Divider().overlay(NexusTheme.border)
                        HStack { Text("RAM: \(vm.ramMB) MB"); Spacer() }
                        Slider(value: Binding(get: { Double(vm.ramMB) }, set: { vm.ramMB = Int(($0 / 256).rounded()) * 256 }), in: 512...8192, step: 256).tint(NexusTheme.cyan)
                    }.padding(12).nexusCard()

                    VStack(spacing: 10) {
                        HStack { Text("Renderer"); Spacer(); Picker("Renderer", selection: $vm.renderer) { ForEach(GraphicsRenderer.allCases) { Text($0.rawValue).tag($0) } }.tint(NexusTheme.cyan) }
                        Divider().overlay(NexusTheme.border)
                        HStack {
                            Text(vm.diskFileName).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Button("Mount") { showPicker = true }.foregroundStyle(NexusTheme.cyan)
                            if !vm.diskImagePath.isEmpty { Button("Eject") { vm.diskImagePath = "" }.foregroundStyle(NexusTheme.amber) }
                        }
                    }.padding(12).nexusCard()

                    HStack {
                        sectionTag("QEMU + SPICE CLI")
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            UIPasteboard.general.string = vm.qemuCommandPreview; copied = true
                        }.font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(NexusTheme.cyan)
                    }
                    Text(vm.qemuCommandPreview).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).nexusCard(elevated: true, radius: 12)

                    HStack(spacing: 10) {
                        Button { store.update(vm); onLaunch(vm) } label: {
                            Label("Boot Graphical VM", systemImage: "display").font(.system(size: 15, weight: .bold)).foregroundStyle(NexusTheme.bg)
                                .frame(maxWidth: .infinity).padding(.vertical, 13).background(NexusTheme.cyan).clipShape(RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                        Button(role: .destructive) { confirmDel = true } label: {
                            Image(systemName: "trash.fill").foregroundStyle(NexusTheme.crimson).frame(width: 48, height: 48)
                                .background(NexusTheme.crimson.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                    }
                }.padding(16)
            }
            .background(NexusTheme.bg).navigationTitle("VM Inspector").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { store.update(vm); settings.impact(.medium); dismiss() }.foregroundStyle(NexusTheme.cyan) }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: UTType.vmDiskTypes, allowsMultipleSelection: false) { res in
                if case .success(let urls) = res, let u = urls.first, let p = try? store.importDisk(from: u) { vm.diskImagePath = p }
            }
            .confirmationDialog("Delete \(vm.name)?", isPresented: $confirmDel, titleVisibility: .visible) {
                Button("Delete VM", role: .destructive) { store.delete(id: vm.id); dismiss() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct SettingsView: View {
    @Environment(JITDetector.self) private var jit
    @Environment(AppSettings.self) private var settings
    @Environment(VMStore.self) private var store
    @State private var purgeMsg: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Settings & StikDebug").font(.system(size: 23, weight: .bold, design: .rounded))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            sectionTag("KERNEL JIT STATUS")
                            Spacer()
                            Button("Probe csops()") { jit.refresh(haptic: true) }
                                .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(NexusTheme.cyan)
                        }
                        kv("PID", "\(jit.pid)")
                        kv("csops(CS_OPS_STATUS)", jit.hexFlags)
                        kv("CS_DEBUGGED (0x10000000)", jit.isJITActive ? "ACTIVE" : "NOT ATTACHED")
                    }.padding(14).nexusCard(borderColor: jit.isJITActive ? NexusTheme.cyan.opacity(0.45) : NexusTheme.amber.opacity(0.45))

                    GlobalPreferencesCard(settings: settings)

                    VStack(alignment: .leading, spacing: 8) {
                        sectionTag("DISK VAULT")
                        kv("Imported Images", "\(store.cachedDiskCount)")
                        Button("Purge Unreferenced Disk Images") {
                            let n = store.purgeUnusedDisks()
                            purgeMsg = n == 0 ? "No unused images found." : "Removed \(n) image(s)."
                        }.font(.system(size: 13, weight: .semibold)).foregroundStyle(NexusTheme.amber)
                            .frame(maxWidth: .infinity).padding(.vertical, 9).background(NexusTheme.amber.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        if let purgeMsg { Text(purgeMsg).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary) }
                    }.padding(14).nexusCard()

                    VStack(alignment: .leading, spacing: 10) {
                        sectionTag("STIKDEBUG JIT ATTACHMENT GUIDE")
                        guide("01", "Pair & Start Local VPN", "Open StikDebug, load your pairing file, and enable the local loopback VPN.")
                        guide("02", "Keep NexusVM Running", "Keep NexusVM active in foreground/switcher (PID \(jit.pid)).")
                        guide("03", "Attach Debugger", "In StikDebug, attach to com.nexusvm.app to set CS_DEBUGGED.")
                        guide("04", "Verify Cyan Badge", "Tap the top-right JIT pill; csops() 0x10000000 turns it cyan.")
                    }.padding(14).nexusCard()
                }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 110)
            }.background(NexusTheme.bg).toolbar(.hidden, for: .navigationBar)
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12, design: .monospaced)).foregroundStyle(NexusTheme.textMuted)
            Spacer()
            Text(v).font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
    }

    private func guide(_ n: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(NexusTheme.bg)
                .padding(.horizontal, 6).padding(.vertical, 3).background(NexusTheme.cyan).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body).font(.system(size: 12)).foregroundStyle(NexusTheme.textSecondary)
            }
        }
    }
}

struct GlobalPreferencesCard: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTag("PREFERENCES")
            Toggle("Auto-Poll StikDebug JIT (3s)", isOn: $settings.autoPollJIT).tint(NexusTheme.cyan)
            Divider().overlay(NexusTheme.border)
            Toggle("Keep Screen Awake", isOn: $settings.keepScreenAwake).tint(NexusTheme.cyan)
            Divider().overlay(NexusTheme.border)
            Toggle("Haptic Feedback", isOn: $settings.hapticsEnabled).tint(NexusTheme.cyan)
            Divider().overlay(NexusTheme.border)
            HStack {
                Text("Default Renderer"); Spacer()
                Picker("Renderer", selection: $settings.defaultRenderer) { ForEach(GraphicsRenderer.allCases) { Text($0.rawValue).tag($0) } }.tint(NexusTheme.cyan)
            }
        }.font(.system(size: 14, weight: .medium)).padding(14).nexusCard()
    }
}
