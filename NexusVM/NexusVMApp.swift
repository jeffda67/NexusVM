import SwiftUI
import Observation
import UniformTypeIdentifiers
import Darwin
import UIKit

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

private enum CSFlags {
    static let opsStatus: UInt32 = 0
    static let debugged: UInt32 = 0x1000_0000
}

extension UTType {
    static let isoImage = UTType(filenameExtension: "iso") ?? UTType("public.iso-image") ?? .data
    static let qcow2Image = UTType(filenameExtension: "qcow2") ?? UTType("com.nexusvm.qcow2-image") ?? .data
    static let rawDiskImage = UTType(filenameExtension: "img") ?? UTType("com.nexusvm.raw-disk-image") ?? .data
    static let vmDiskTypes: [UTType] = [.isoImage, .qcow2Image, .rawDiskImage, .data]
}

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
    var subtitle: String { self == .virtualize ? "Native ARM64 / Hypervisor fast path" : "TCG dynamic binary translation (JIT)" }
}

enum CPUArchitecture: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case x86_64 = "x86_64", arm64 = "ARM64", riscV = "RISC-V"
    var id: String { rawValue }
    var binary: String {
        switch self {
        case .x86_64: return "qemu-system-x86_64"
        case .arm64: return "qemu-system-aarch64"
        case .riscV: return "qemu-system-riscv64"
        }
    }
    var machine: String {
        switch self {
        case .x86_64: return "q35"
        case .arm64: return "virt,highmem=on"
        case .riscV: return "virt"
        }
    }
}

enum GraphicsRenderer: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case metal = "Metal", angle = "ANGLE", vga = "VGA"
    var id: String { rawValue }
    var deviceFlag: String {
        switch self {
        case .metal: return "virtio-gpu-gl-pci,virgl=on"
        case .angle: return "virtio-gpu-pci"
        case .vga: return "VGA,vgamem_mb=64"
        }
    }
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
    var qemuCommandPreview: String {
        var args = [
            architecture.binary,
            "-M \(architecture.machine)",
            (mode == .virtualize && architecture == .arm64) ? "-accel hvf" : "-accel tcg,thread=multi",
            "-smp \(cpuCores)",
            "-m \(ramMB)",
            "-device \(renderer.deviceFlag)",
            "-netdev \(networkMode.netdevFlag)",
            "-device virtio-net-pci,netdev=net0"
        ]
        if !diskImagePath.isEmpty {
            let ext = URL(fileURLWithPath: diskImagePath).pathExtension.lowercased()
            if ext == "iso" {
                args.append("-cdrom \"\(diskFileName)\" -boot d")
            } else {
                args.append("-drive file=\"\(diskFileName)\",if=virtio,format=\(ext == "qcow2" ? "qcow2" : "raw")")
            }
        }
        let extra = customQEMUArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { args.append(extra) }
        return args.joined(separator: " \\\n  ")
    }
}

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
        return files.filter { !used.contains($0.path) }.reduce(0) { count, url in
            count + ((try? fm.removeItem(at: url)) != nil ? 1 : 0)
        }
    }

    var totalRAMMB: Int { machines.reduce(0) { $0 + $1.ramMB } }
    var activeCount: Int { machines.filter { $0.status == .running }.count }

    private static func defaults() -> [VirtualMachine] {
        [
            VirtualMachine(name: "Alpine Edge ARM64", osPreset: .linux, mode: .virtualize, architecture: .arm64, cpuCores: 4, ramMB: 2048, storageGB: 24, renderer: .metal, networkMode: .nat, diskImagePath: "alpine-virt-3.21-aarch64.iso", customQEMUArgs: "-nographic -serial mon:stdio"),
            VirtualMachine(name: "Windows 11 x64", osPreset: .windows, mode: .emulate, architecture: .x86_64, cpuCores: 4, ramMB: 4096, storageGB: 64, renderer: .angle, networkMode: .nat, diskImagePath: "win11_24h2_x64.qcow2", customQEMUArgs: "-cpu max,+avx2")
        ]
    }
}

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
    @State private var consoleVM: VirtualMachine?
    @State private var inspectVM: VirtualMachine?

    var body: some View {
        ZStack(alignment: .bottom) {
            NexusTheme.bg.ignoresSafeArea()
            Group {
                switch tab {
                case .machines:
                    MachinesDashboardView(
                        onConsole: { vm in
                            store.setStatus(.running, for: vm.id)
                            consoleVM = store.machines.first { $0.id == vm.id } ?? vm
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
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(active ? NexusTheme.cyan : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.ultraThinMaterial)
            .background(NexusTheme.card.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(NexusTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .sheet(item: $inspectVM) { vm in
            VMInspectorView(vm: vm) { launched in
                inspectVM = nil
                store.setStatus(.running, for: launched.id)
                consoleVM = store.machines.first { $0.id == launched.id } ?? launched
            }
        }
        .fullScreenCover(item: $consoleVM) { vm in
            ActiveVMConsoleView(vm: vm)
        }
    }
}

struct JITStatusPill: View {
    @Environment(JITDetector.self) private var jit
    @State private var showInfo = false

    var body: some View {
        let tint = jit.isJITActive ? NexusTheme.cyan : NexusTheme.amber
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { jit.refresh(haptic: true) }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(tint).frame(width: 8, height: 8).shadow(color: tint.opacity(0.8), radius: 4)
                    Text(jit.isJITActive ? "JIT Active" : "Waiting for StikDebug")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint)
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold)).foregroundStyle(NexusTheme.textSecondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(tint.opacity(0.12))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.38), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.system(size: 15)).foregroundStyle(NexusTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .alert("csops() Kernel Status", isPresented: $showInfo) {
            Button("Refresh") { jit.refresh(haptic: true) }
            Button("OK", role: .cancel) {}
        } message: {
            Text("PID: \(jit.pid)\nFlags: \(jit.hexFlags)\nCS_DEBUGGED (0x10000000): \(jit.isJITActive ? "SET" : "UNSET")\nChecks: \(jit.checkCount)")
        }
    }
}

struct MachinesDashboardView: View {
    @Environment(VMStore.self) private var store
    @Environment(AppSettings.self) private var settings
    let onConsole: (VirtualMachine) -> Void
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
                                Text("NexusVM").font(.system(size: 23, weight: .bold, design: .rounded)).foregroundStyle(NexusTheme.textPrimary)
                            }
                            Text("iOS 27 Hypervisor & QEMU").font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary)
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

                        Button {
                            withAnimation { grid.toggle() }
                            settings.impact(.light)
                        } label: {
                            Image(systemName: grid ? "list.bullet" : "square.grid.2x2")
                                .foregroundStyle(NexusTheme.cyan)
                                .frame(width: 40, height: 38).nexusCard(radius: 12)
                        }
                        .buttonStyle(.plain)
                    }

                    if filtered.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "server.rack").font(.system(size: 32)).foregroundStyle(NexusTheme.textMuted)
                            Text("No Virtual Machines").font(.headline)
                            Text("Use the Create tab to configure a VM.").font(.caption).foregroundStyle(NexusTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 36).nexusCard()
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
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10).nexusCard(radius: 12)
    }

    private func statusBadge(_ status: VMStatus) -> some View {
        HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.rawValue.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(status.color)
        }
        .padding(.horizontal, 7).padding(.vertical, 3).background(status.color.opacity(0.14)).clipShape(Capsule())
    }

    private func chip(_ text: String, _ tint: Color = NexusTheme.textSecondary) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 3).nexusCard(elevated: true, radius: 6)
    }

    private func vmCard(_ vm: VirtualMachine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: vm.osPreset.symbol)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(vm.osPreset.tint)
                    .frame(width: 34, height: 34).background(vm.osPreset.tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer()
                statusBadge(vm.status)
            }
            Text(vm.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(vm.diskFileName).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.textMuted).lineLimit(1)
            HStack(spacing: 5) {
                chip(vm.architecture.rawValue, NexusTheme.cyan)
                chip("\(vm.cpuCores)C")
                chip(vm.formattedRAM)
            }
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
                    Button { store.setStatus(.stopped, for: vm.id); settings.impact(.light) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(NexusTheme.crimson)
                            .frame(width: 32, height: 32).background(NexusTheme.crimson.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }.buttonStyle(.plain)
                }
                Button { onConsole(vm) } label: {
                    Image(systemName: "terminal").font(.system(size: 13)).frame(width: 32, height: 32).nexusCard(elevated: true, radius: 9)
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .nexusCard(borderColor: vm.status == .running ? NexusTheme.emerald.opacity(0.45) : NexusTheme.border)
        .contentShape(Rectangle())
        .onTapGesture { onInspect(vm) }
        .contextMenu {
            Button("Console", systemImage: "terminal") { onConsole(vm) }
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
                HStack(spacing: 6) {
                    Text(vm.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    statusBadge(vm.status)
                }
                HStack(spacing: 5) {
                    chip(vm.architecture.rawValue, NexusTheme.cyan)
                    chip("\(vm.cpuCores)C")
                    chip(vm.formattedRAM)
                }
            }
            Spacer()
            Button { togglePlay(vm) } label: {
                Image(systemName: vm.status == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(NexusTheme.bg)
                    .frame(width: 32, height: 32).background(vm.status == .running ? NexusTheme.amber : NexusTheme.cyan)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }.buttonStyle(.plain)
            if vm.status != .stopped {
                Button { store.setStatus(.stopped, for: vm.id) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(NexusTheme.crimson)
                        .frame(width: 32, height: 32).background(NexusTheme.crimson.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }.buttonStyle(.plain)
            }
        }
        .padding(12).nexusCard(borderColor: vm.status == .running ? NexusTheme.emerald.opacity(0.45) : NexusTheme.border)
        .contentShape(Rectangle())
        .onTapGesture { onInspect(vm) }
    }

    private func togglePlay(_ vm: VirtualMachine) {
        settings.impact(.medium)
        if vm.status == .running { store.setStatus(.paused, for: vm.id) } else { onConsole(vm) }
    }
}

struct CreateVMWizardView: View {
    @Environment(VMStore.self) private var store
    @Environment(AppSettings.self) private var settings
    let onCreate: (VirtualMachine) -> Void

    @State private var step = 0
    @State private var name = "Linux Dev Guest"
    @State private var osPreset: OSPreset = .linux
    @State private var mode: ExecutionMode = .virtualize
    @State private var arch: CPUArchitecture = .arm64
    @State private var cores = 4
    @State private var ramMB = 2048
    @State private var storageGB = 24
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
                        ForEach(0..<3, id: \.self) { i in
                            Capsule().fill(i <= step ? NexusTheme.cyan : NexusTheme.border).frame(height: 4)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if step == 0 { stepOne } else if step == 1 { stepTwo } else { stepThree }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 140)
                }
            }
            .background(NexusTheme.bg)
            .toolbar(.hidden, for: .navigationBar)
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
                        let vm = VirtualMachine(
                            name: clean.isEmpty ? "\(osPreset.rawValue) VM" : clean,
                            osPreset: osPreset, mode: mode, architecture: arch,
                            cpuCores: cores, ramMB: ramMB, storageGB: storageGB,
                            renderer: renderer, networkMode: network,
                            diskImagePath: diskPath, customQEMUArgs: extraArgs
                        )
                        settings.impact(.medium)
                        onCreate(vm)
                    }
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(NexusTheme.bg)
                    .frame(maxWidth: .infinity).padding(.vertical, 13).background(NexusTheme.cyan)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 16).padding(.bottom, 84)
            }
            .onAppear { renderer = settings.defaultRenderer }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: UTType.vmDiskTypes, allowsMultipleSelection: false) { res in
                switch res {
                case .success(let urls):
                    if let url = urls.first {
                        do {
                            diskPath = try store.importDisk(from: url)
                            importNote = "Imported \(URL(fileURLWithPath: diskPath).lastPathComponent)"
                        } catch { importNote = "Error: \(error.localizedDescription)" }
                    }
                case .failure(let err): importNote = "Error: \(err.localizedDescription)"
                }
            }
        }
    }

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTag("MACHINE NAME")
            TextField("e.g. Debian 13 ARM64", text: $name).padding(12).nexusCard(radius: 12)

            sectionTag("EXECUTION MODE")
            ForEach(ExecutionMode.allCases) { item in
                Button { mode = item; settings.impact(.light) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.rawValue).font(.system(size: 15, weight: .semibold)).foregroundStyle(NexusTheme.textPrimary)
                            Text(item.subtitle).font(.system(size: 12)).foregroundStyle(NexusTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: mode == item ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(mode == item ? NexusTheme.cyan : NexusTheme.textMuted)
                    }
                    .padding(12).nexusCard(borderColor: mode == item ? NexusTheme.cyan : NexusTheme.border, radius: 12)
                }.buttonStyle(.plain)
            }

            sectionTag("OS PRESET")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(OSPreset.allCases) { p in
                    Button {
                        osPreset = p; mode = p.defaultMode; arch = p.defaultArch
                        ramMB = p.defaultRAM; storageGB = p.defaultStorage
                        name = "\(p.rawValue) VM"; settings.impact(.light)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: p.symbol).font(.system(size: 18)).foregroundStyle(p.tint)
                            Text(p.rawValue).font(.system(size: 14, weight: .semibold)).foregroundStyle(NexusTheme.textPrimary)
                            Text(p.defaultArch.rawValue).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
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
                HStack(spacing: 6) {
                    ForEach([512, 1024, 2048, 4096, 8192], id: \.self) { m in
                        Button(m >= 1024 ? "\(m/1024)G" : "\(m)M") { ramMB = m }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(ramMB == m ? NexusTheme.bg : NexusTheme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(ramMB == m ? NexusTheme.cyan : NexusTheme.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.padding(12).nexusCard()

            VStack(alignment: .leading, spacing: 8) {
                HStack { sectionTag("DISK CAPACITY"); Spacer(); Text("\(storageGB) GB").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(NexusTheme.cyan) }
                Slider(value: Binding(get: { Double(storageGB) }, set: { storageGB = Int($0.rounded()) }), in: 8...256, step: 4).tint(NexusTheme.cyan)
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
            sectionTag("BOOT IMAGE (.ISO / .QCOW2 / .IMG)")
            Button { showImporter = true } label: {
                HStack {
                    Image(systemName: diskPath.isEmpty ? "folder.badge.plus" : "opticaldisc.fill").foregroundStyle(NexusTheme.cyan)
                    Text(diskPath.isEmpty ? "Import Image from Files App" : URL(fileURLWithPath: diskPath).lastPathComponent)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(NexusTheme.textPrimary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(NexusTheme.textMuted)
                }
                .padding(14).nexusCard(borderColor: diskPath.isEmpty ? NexusTheme.border : NexusTheme.cyan.opacity(0.6))
            }.buttonStyle(.plain)

            if let importNote {
                Text(importNote).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(importNote.hasPrefix("Error") ? NexusTheme.crimson : NexusTheme.emerald)
            }

            sectionTag("CUSTOM QEMU FLAGS")
            TextField("-cpu max -serial mon:stdio", text: $extraArgs)
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(NexusTheme.cyan)
                .autocorrectionDisabled().textInputAutocapitalization(.never).padding(12).nexusCard(radius: 12)
        }
    }
}

struct ConsoleLine: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let color: Color
}

struct ActiveVMConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(VMStore.self) private var store
    @Environment(JITDetector.self) private var jit
    @Environment(AppSettings.self) private var settings

    @State var vm: VirtualMachine
    @State private var lines: [ConsoleLine] = []
    @State private var input = ""
    @State private var zoom: CGFloat = 1.0
    @State private var liveZoom: CGFloat = 1.0
    @State private var collapsed = false
    @State private var showISO = false
    @State private var showSnap = false
    @State private var showHalt = false
    @State private var snapTime = ""
    @State private var cpuPct = 16
    @FocusState private var kbFocused: Bool

    private var scale: CGFloat { min(2.5, max(1.0, zoom * liveZoom)) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(hex: 0x07080B).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Label("Exit", systemImage: "chevron.left").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6).nexusCard(elevated: true, radius: 9)
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading) {
                        Text(vm.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                        Text("\(vm.architecture.rawValue) · \(vm.mode.rawValue) · \(String(format: "%.1fx", scale))")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary)
                    }
                    Spacer()
                    Text(jit.isJITActive ? "JIT" : "NO JIT")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(jit.isJITActive ? NexusTheme.cyan : NexusTheme.amber)
                        .padding(.horizontal, 8).padding(.vertical, 4).nexusCard(radius: 99)
                }
                .padding(.horizontal, 14).padding(.vertical, 10).background(NexusTheme.bg)

                HStack(spacing: 12) {
                    Text("CPU \(cpuPct)%")
                    Text(vm.formattedRAM)
                    Text(vm.renderer.rawValue)
                    Spacer()
                    Text(vm.diskFileName).lineLimit(1).foregroundStyle(NexusTheme.cyan)
                }
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 6).background(NexusTheme.card)

                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView([.vertical, .horizontal]) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(lines) { line in
                                    Text(line.text).font(.system(size: settings.consoleFontSize, design: .monospaced)).foregroundStyle(line.color)
                                }
                                HStack(spacing: 6) {
                                    Text("root@nexusvm:~#").font(.system(size: settings.consoleFontSize, weight: .bold, design: .monospaced)).foregroundStyle(NexusTheme.cyan)
                                    TextField("command...", text: $input)
                                        .font(.system(size: settings.consoleFontSize, design: .monospaced))
                                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                                        .focused($kbFocused).submitLabel(.send).onSubmit(runCommand)
                                }
                                .padding(.top, 4).id("BOTTOM")
                            }
                            .padding(14)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                            .scaleEffect(scale, anchor: .topLeading)
                        }
                        .onChange(of: lines.count) { _, _ in
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                        }
                    }
                    .gesture(
                        MagnifyGesture()
                            .onChanged { liveZoom = $0.magnification }
                            .onEnded { zoom = min(2.5, max(1.0, zoom * $0.magnification)); liveZoom = 1.0 }
                    )
                    .onTapGesture(count: 2) { withAnimation { zoom = 1.0; liveZoom = 1.0 } }
                }
            }

            VStack(spacing: 8) {
                if !collapsed {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            macro("Ctrl+Alt+Del") { log("[KEY] Ctrl+Alt+Del", NexusTheme.amber) }
                            macro("Esc") { log("[KEY] ESC", NexusTheme.textSecondary) }
                            macro("Tab") { log("[KEY] TAB", NexusTheme.textSecondary) }
                            macro("Ctrl+C") { log("^C", NexusTheme.crimson) }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button { withAnimation { collapsed.toggle() } } label: {
                        Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                            .foregroundStyle(NexusTheme.cyan).frame(width: 36, height: 36).nexusCard(elevated: true, radius: 10)
                    }.buttonStyle(.plain)

                    if !collapsed {
                        toolBtn("keyboard", "Keys", kbFocused ? NexusTheme.cyan : NexusTheme.textPrimary) { kbFocused.toggle() }
                        toolBtn("opticaldisc", vm.diskImagePath.isEmpty ? "Mount" : "Eject", NexusTheme.textPrimary) {
                            if vm.diskImagePath.isEmpty { showISO = true }
                            else { let f = vm.diskFileName; vm.diskImagePath = ""; store.update(vm); log("[MEDIA] Ejected \(f)", NexusTheme.amber) }
                        }
                        toolBtn("camera.aperture", "Snap", NexusTheme.emerald) {
                            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; snapTime = f.string(from: Date())
                            log("[QEMU] savevm \(snapTime) OK", NexusTheme.emerald); showSnap = true
                        }
                        toolBtn("power", "Halt", NexusTheme.crimson) { showHalt = true }
                    }
                }
            }
            .padding(10).background(.ultraThinMaterial).background(NexusTheme.card.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(NexusTheme.border, lineWidth: 1))
            .padding(14)
        }
        .preferredColorScheme(.dark)
        .task { await boot() }
        .task {
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); cpuPct = Int.random(in: 8...42) }
        }
        .fileImporter(isPresented: $showISO, allowedContentTypes: UTType.vmDiskTypes, allowsMultipleSelection: false) { res in
            if case .success(let urls) = res, let u = urls.first, let path = try? store.importDisk(from: u) {
                vm.diskImagePath = path; store.update(vm); log("[MEDIA] Mounted \(vm.diskFileName)", NexusTheme.emerald)
            }
        }
        .alert("Snapshot Saved", isPresented: $showSnap) { Button("OK", role: .cancel) {} } message: {
            Text("Captured live VM state for \(vm.name) at \(snapTime).")
        }
        .confirmationDialog("Force Shutdown?", isPresented: $showHalt, titleVisibility: .visible) {
            Button("Force Power Off", role: .destructive) { store.setStatus(.stopped, for: vm.id); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func macro(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 6).nexusCard(elevated: true, radius: 8)
    }

    private func toolBtn(_ icon: String, _ label: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(tint).frame(maxWidth: .infinity).padding(.vertical, 6).nexusCard(elevated: true, radius: 10)
        }.buttonStyle(.plain)
    }

    private func log(_ text: String, _ color: Color = NexusTheme.textPrimary) { lines.append(ConsoleLine(text: text, color: color)) }

    private func boot() async {
        guard lines.isEmpty else { return }
        let items: [(String, Color)] = [
            ("[NEXUSVM] Starting \(vm.architecture.binary) (\(vm.mode.rawValue))", NexusTheme.cyan),
            ("[KERNEL] csops = \(jit.hexFlags) [JIT: \(jit.isJITActive ? "ACTIVE" : "INTERPRETER")]", jit.isJITActive ? NexusTheme.emerald : NexusTheme.amber),
            ("[MEM] \(vm.ramMB) MiB RAM · \(vm.cpuCores) vCPU · \(vm.renderer.rawValue)", NexusTheme.textSecondary),
            ("[MEDIA] \(vm.diskFileName)", NexusTheme.textPrimary),
            ("[SHELL] Ready. Type 'help' for commands. Pinch to zoom.", NexusTheme.cyan)
        ]
        for (t, c) in items {
            if Task.isCancelled { return }
            log(t, c)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func runCommand() {
        let cmd = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        guard !cmd.isEmpty else { return }
        log("root@nexusvm:~# \(cmd)", NexusTheme.cyan)
        switch cmd.lowercased() {
        case "help": log("help, uname -a, lscpu, free -h, df -h, ip addr, clear, reboot, poweroff", NexusTheme.textSecondary)
        case "uname -a": log("Linux nexusvm 6.14.0-nexus #1 SMP \(vm.architecture.rawValue) GNU/Linux")
        case "lscpu": log("\(vm.architecture.rawValue) · \(vm.cpuCores) vCPU · JIT: \(jit.isJITActive ? "ON" : "OFF")")
        case "free -h": log("Mem: \(vm.ramMB)Mi total, \(max(128, vm.ramMB / 5))Mi used")
        case "df -h": log("/dev/vda1 \(vm.storageGB)G (14% used)")
        case "ip addr": log("eth0: 10.0.2.15/24 (\(vm.networkMode.rawValue))")
        case "clear": lines.removeAll()
        case "reboot": lines.removeAll(); Task { await boot() }
        case "poweroff", "exit": store.setStatus(.stopped, for: vm.id); dismiss()
        default: log("sh: \(cmd): exit 0", NexusTheme.textSecondary)
        }
    }
}

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
                        Divider().overlay(NexusTheme.border)
                        Stepper("Storage: \(vm.storageGB) GB", value: $vm.storageGB, in: 8...512, step: 4)
                    }.padding(12).nexusCard()

                    VStack(spacing: 10) {
                        HStack { Text("Renderer"); Spacer(); Picker("Renderer", selection: $vm.renderer) { ForEach(GraphicsRenderer.allCases) { Text($0.rawValue).tag($0) } }.tint(NexusTheme.cyan) }
                        Divider().overlay(NexusTheme.border)
                        HStack { Text("Network"); Spacer(); Picker("Network", selection: $vm.networkMode) { ForEach(NetworkMode.allCases) { Text($0.rawValue).tag($0) } }.tint(NexusTheme.cyan) }
                        Divider().overlay(NexusTheme.border)
                        HStack {
                            Text(vm.diskFileName).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Button("Mount") { showPicker = true }.foregroundStyle(NexusTheme.cyan)
                            if !vm.diskImagePath.isEmpty { Button("Eject") { vm.diskImagePath = "" }.foregroundStyle(NexusTheme.amber) }
                        }
                    }.padding(12).nexusCard()

                    sectionTag("CUSTOM QEMU ARGS")
                    TextEditor(text: $vm.customQEMUArgs).font(.system(size: 12, design: .monospaced)).foregroundStyle(NexusTheme.cyan)
                        .scrollContentBackground(.hidden).frame(minHeight: 68).padding(10).nexusCard(radius: 12)

                    HStack {
                        sectionTag("QEMU CLI")
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            UIPasteboard.general.string = vm.qemuCommandPreview; copied = true
                        }.font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(NexusTheme.cyan)
                    }
                    Text(vm.qemuCommandPreview).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).nexusCard(elevated: true, radius: 12)

                    HStack(spacing: 10) {
                        Button { store.update(vm); onLaunch(vm) } label: {
                            Label("Launch Console", systemImage: "terminal.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(NexusTheme.bg)
                                .frame(maxWidth: .infinity).padding(.vertical, 13).background(NexusTheme.cyan)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                        Button(role: .destructive) { confirmDel = true } label: {
                            Image(systemName: "trash.fill").foregroundStyle(NexusTheme.crimson).frame(width: 48, height: 48)
                                .background(NexusTheme.crimson.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                    }
                }.padding(16)
            }
            .background(NexusTheme.bg)
            .navigationTitle("VM Inspector").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.update(vm); settings.impact(.medium); dismiss() }.foregroundStyle(NexusTheme.cyan)
                }
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
                    }
                    .padding(14).nexusCard(borderColor: jit.isJITActive ? NexusTheme.cyan.opacity(0.45) : NexusTheme.amber.opacity(0.45))

                    GlobalPreferencesCard(settings: settings)

                    VStack(alignment: .leading, spacing: 8) {
                        sectionTag("DISK VAULT")
                        kv("Imported Images", "\(store.cachedDiskCount)")
                        Button("Purge Unreferenced Disk Images") {
                            let n = store.purgeUnusedDisks()
                            purgeMsg = n == 0 ? "No unused images found." : "Removed \(n) image(s)."
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(NexusTheme.amber)
                        .frame(maxWidth: .infinity).padding(.vertical, 9).background(NexusTheme.amber.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        if let purgeMsg { Text(purgeMsg).font(.system(size: 11, design: .monospaced)).foregroundStyle(NexusTheme.textSecondary) }
                    }.padding(14).nexusCard()

                    VStack(alignment: .leading, spacing: 10) {
                        sectionTag("STIKDEBUG JIT ATTACHMENT GUIDE")
                        guide("01", "Pair & Start Local VPN", "Open StikDebug, load your pairing file, and enable the local loopback VPN tunnel.")
                        guide("02", "Keep NexusVM Running", "Keep NexusVM active in foreground/switcher (PID \(jit.pid)).")
                        guide("03", "Attach Debugger", "In StikDebug, attach to com.nexusvm.app to set CS_DEBUGGED.")
                        guide("04", "Verify Cyan Badge", "Tap the top-right JIT pill; csops() 0x10000000 turns it cyan (JIT Active).")
                    }.padding(14).nexusCard()
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 110)
            }
            .background(NexusTheme.bg)
            .toolbar(.hidden, for: .navigationBar)
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
                Text("Default Renderer")
                Spacer()
                Picker("Renderer", selection: $settings.defaultRenderer) { ForEach(GraphicsRenderer.allCases) { Text($0.rawValue).tag($0) } }.tint(NexusTheme.cyan)
            }
            Divider().overlay(NexusTheme.border)
            HStack {
                Text("Console Font: \(Int(settings.consoleFontSize))pt")
                Slider(value: $settings.consoleFontSize, in: 10...18, step: 1).tint(NexusTheme.cyan)
            }
        }
        .font(.system(size: 14, weight: .medium)).padding(14).nexusCard()
    }
}
