import SwiftUI
import Observation
import UniformTypeIdentifiers
import Darwin
import UIKit

// MARK: - Darwin csops Bridge (Zero C Header Dependencies)

@_silgen_name("csops")
private func csops(
    _ pid: pid_t,
    _ ops: UInt32,
    _ useraddr: UnsafeMutableRawPointer?,
    _ usersize: Int
) -> Int32

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
    static let background = Color(hex: 0x0D0E12)
    static let surface = Color(hex: 0x16181F)
    static let surfaceElevated = Color(hex: 0x1D202A)
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
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

struct NexusCardModifier: ViewModifier {
    var elevated: Bool = false
    var borderColor: Color = NexusTheme.border
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(elevated ? NexusTheme.surfaceElevated : NexusTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
    }
}

extension View {
    func nexusCard(
        elevated: Bool = false,
        borderColor: Color = NexusTheme.border,
        cornerRadius: CGFloat = 16
    ) -> some View {
        modifier(NexusCardModifier(elevated: elevated, borderColor: borderColor, cornerRadius: cornerRadius))
    }
}

// MARK: - Domain Models

enum OSPreset: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case linux = "Linux"
    case windows = "Windows"
    case macOS = "macOS"
    case customISO = "Custom ISO"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .linux: return "terminal.fill"
        case .windows: return "square.grid.2x2.fill"
        case .macOS: return "apple.logo"
        case .customISO: return "opticaldisc.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .linux: return NexusTheme.cyan
        case .windows: return Color(hex: 0x4DA6FF)
        case .macOS: return Color(hex: 0xD2DAE8)
        case .customISO: return NexusTheme.amber
        }
    }

    var defaultArchitecture: CPUArchitecture {
        switch self {
        case .linux: return .arm64
        case .windows: return .x86_64
        case .macOS: return .arm64
        case .customISO: return .x86_64
        }
    }

    var defaultMode: ExecutionMode {
        switch self {
        case .linux, .macOS: return .virtualize
        case .windows, .customISO: return .emulate
        }
    }

    var defaultRAMMB: Int {
        switch self {
        case .linux: return 2048
        case .windows: return 4096
        case .macOS: return 4096
        case .customISO: return 2048
        }
    }

    var defaultStorageGB: Int {
        switch self {
        case .linux: return 24
        case .windows: return 64
        case .macOS: return 64
        case .customISO: return 16
        }
    }
}

enum ExecutionMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case virtualize = "Virtualize"
    case emulate = "Emulate"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .virtualize: return "Native ARM64 / Hypervisor fast path"
        case .emulate: return "TCG dynamic binary translation (JIT)"
        }
    }
}

enum CPUArchitecture: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case x86_64 = "x86_64"
    case arm64 = "ARM64"
    case riscV = "RISC-V"

    var id: String { rawValue }

    var qemuBinary: String {
        switch self {
        case .x86_64: return "qemu-system-x86_64"
        case .arm64: return "qemu-system-aarch64"
        case .riscV: return "qemu-system-riscv64"
        }
    }

    var machineFlag: String {
        switch self {
        case .x86_64: return "q35"
        case .arm64: return "virt,highmem=on"
        case .riscV: return "virt"
        }
    }
}

enum GraphicsRenderer: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case metal = "Metal"
    case angle = "ANGLE"
    case vga = "VGA"

    var id: String { rawValue }

    var qemuDeviceFlag: String {
        switch self {
        case .metal: return "virtio-gpu-gl-pci,virgl=on"
        case .angle: return "virtio-gpu-pci"
        case .vga: return "VGA,vgamem_mb=64"
        }
    }
}

enum NetworkMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case nat = "NAT"
    case bridged = "Bridged"

    var id: String { rawValue }

    var qemuNetdevFlag: String {
        switch self {
        case .nat: return "user,id=net0,hostfwd=tcp::2222-:22"
        case .bridged: return "vmnet-bridged,id=net0,ifname=en0"
        }
    }
}

enum VMStatus: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case stopped = "Stopped"
    case running = "Running"
    case paused = "Paused"

    var id: String { rawValue }

    var badgeColor: Color {
        switch self {
        case .stopped: return NexusTheme.textMuted
        case .running: return NexusTheme.emerald
        case .paused: return NexusTheme.amber
        }
    }
}

struct VirtualMachine: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var osPreset: OSPreset
    var mode: ExecutionMode
    var architecture: CPUArchitecture
    var cpuCores: Int
    var ramMB: Int
    var storageGB: Int
    var renderer: GraphicsRenderer
    var networkMode: NetworkMode
    var diskImagePath: String
    var customQEMUArgs: String
    var status: VMStatus
    var createdAt: Date
    var lastBootedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        osPreset: OSPreset,
        mode: ExecutionMode,
        architecture: CPUArchitecture,
        cpuCores: Int,
        ramMB: Int,
        storageGB: Int,
        renderer: GraphicsRenderer,
        networkMode: NetworkMode,
        diskImagePath: String = "",
        customQEMUArgs: String = "",
        status: VMStatus = .stopped,
        createdAt: Date = Date(),
        lastBootedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.osPreset = osPreset
        self.mode = mode
        self.architecture = architecture
        self.cpuCores = cpuCores
        self.ramMB = ramMB
        self.storageGB = storageGB
        self.renderer = renderer
        self.networkMode = networkMode
        self.diskImagePath = diskImagePath
        self.customQEMUArgs = customQEMUArgs
        self.status = status
        self.createdAt = createdAt
        self.lastBootedAt = lastBootedAt
    }

    var diskImageFileName: String {
        guard !diskImagePath.isEmpty else { return "No Disk Attached" }
        return URL(fileURLWithPath: diskImagePath).lastPathComponent
    }

    var formattedRAM: String {
        if ramMB >= 1024 && ramMB % 1024 == 0 {
            return "\(ramMB / 1024) GB"
        }
        return "\(ramMB) MB"
    }

    var qemuCommandPreview: String {
        var parts: [String] = [
            architecture.qemuBinary,
            "-M \(architecture.machineFlag)",
            mode == .virtualize && architecture == .arm64 ? "-accel hvf" : "-accel tcg,thread=multi",
            "-smp \(cpuCores)",
            "-m \(ramMB)",
            "-device \(renderer.qemuDeviceFlag)",
            "-netdev \(networkMode.qemuNetdevFlag)",
            "-device virtio-net-pci,netdev=net0"
        ]
        if !diskImagePath.isEmpty {
            let ext = URL(fileURLWithPath: diskImagePath).pathExtension.lowercased()
            if ext == "iso" {
                parts.append("-cdrom \"\(diskImageFileName)\"")
                parts.append("-boot d")
            } else {
                let format = ext == "qcow2" ? "qcow2" : "raw"
                parts.append("-drive file=\"\(diskImageFileName)\",if=virtio,format=\(format)")
            }
        }
        let trimmedArgs = customQEMUArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedArgs.isEmpty {
            parts.append(trimmedArgs)
        }
        return parts.joined(separator: " \\\n  ")
    }
}

// MARK: - Live StikDebug JIT Detector

@Observable
@MainActor
final class JITDetector {
    private(set) var isJITActive: Bool = false
    private(set) var rawFlags: UInt32 = 0
    private(set) var lastChecked: Date = Date()
    private(set) var checkCount: Int = 0
    private(set) var pid: pid_t = getpid()

    init() {
        refresh(triggerHaptic: false)
    }

    var hexFlags: String {
        String(format: "0x%08X", rawFlags)
    }

    func refresh(triggerHaptic: Bool = true) {
        pid = getpid()
        var flags: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &flags) { pointer in
            csops(pid, CSFlags.opsStatus, UnsafeMutableRawPointer(pointer), MemoryLayout<UInt32>.size)
        }
        if status == 0 {
            rawFlags = flags
            isJITActive = (flags & CSFlags.debugged) != 0
        } else {
            rawFlags = 0
            isJITActive = false
        }
        lastChecked = Date()
        checkCount += 1

        if triggerHaptic {
            let generator = UIImpactFeedbackGenerator(style: isJITActive ? .medium : .light)
            generator.impactOccurred()
        }
    }
}

// MARK: - App Settings

@Observable
@MainActor
final class AppSettings {
    var autoPollJIT: Bool {
        didSet { UserDefaults.standard.set(autoPollJIT, forKey: Keys.autoPollJIT) }
    }
    var keepScreenAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenAwake, forKey: Keys.keepScreenAwake)
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        }
    }
    var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: Keys.hapticsEnabled) }
    }
    var consoleFontSize: Double {
        didSet { UserDefaults.standard.set(consoleFontSize, forKey: Keys.consoleFontSize) }
    }
    var defaultRenderer: GraphicsRenderer {
        didSet { UserDefaults.standard.set(defaultRenderer.rawValue, forKey: Keys.defaultRenderer) }
    }

    private enum Keys {
        static let autoPollJIT = "nexusvm.autoPollJIT"
        static let keepScreenAwake = "nexusvm.keepScreenAwake"
        static let hapticsEnabled = "nexusvm.hapticsEnabled"
        static let consoleFontSize = "nexusvm.consoleFontSize"
        static let defaultRenderer = "nexusvm.defaultRenderer"
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.autoPollJIT) == nil {
            defaults.set(true, forKey: Keys.autoPollJIT)
        }
        if defaults.object(forKey: Keys.keepScreenAwake) == nil {
            defaults.set(true, forKey: Keys.keepScreenAwake)
        }
        if defaults.object(forKey: Keys.hapticsEnabled) == nil {
            defaults.set(true, forKey: Keys.hapticsEnabled)
        }
        if defaults.object(forKey: Keys.consoleFontSize) == nil {
            defaults.set(12.0, forKey: Keys.consoleFontSize)
        }

        self.autoPollJIT = defaults.bool(forKey: Keys.autoPollJIT)
        self.keepScreenAwake = defaults.bool(forKey: Keys.keepScreenAwake)
        self.hapticsEnabled = defaults.bool(forKey: Keys.hapticsEnabled)
        self.consoleFontSize = max(10.0, min(18.0, defaults.double(forKey: Keys.consoleFontSize)))
        let savedRenderer = defaults.string(forKey: Keys.defaultRenderer) ?? GraphicsRenderer.metal.rawValue
        self.defaultRenderer = GraphicsRenderer(rawValue: savedRenderer) ?? .metal

        UIApplication.shared.isIdleTimerDisabled = self.keepScreenAwake
    }

    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - VM Persistence & Disk Image Manager

@Observable
@MainActor
final class VMStore {
    private(set) var machines: [VirtualMachine] = []
    var lastError: String?

    private let fileManager = FileManager.default

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    private var storeURL: URL {
        documentsDirectory.appendingPathComponent("NexusVM_VMs.json")
    }

    private var diskImagesDirectory: URL {
        documentsDirectory.appendingPathComponent("DiskImages", isDirectory: true)
    }

    init() {
        ensureDirectories()
        load()
    }

    private func ensureDirectories() {
        if !fileManager.fileExists(atPath: diskImagesDirectory.path) {
            try? fileManager.createDirectory(at: diskImagesDirectory, withIntermediateDirectories: true)
        }
    }

    func load() {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            machines = Self.seedDefaults()
            save()
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            machines = try decoder.decode([VirtualMachine].self, from: data)
        } catch {
            lastError = "Failed to load VM registry: \(error.localizedDescription)"
            machines = []
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(machines)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            lastError = "Failed to persist VM registry: \(error.localizedDescription)"
        }
    }

    func add(_ vm: VirtualMachine) {
        machines.insert(vm, at: 0)
        save()
    }

    func update(_ vm: VirtualMachine) {
        guard let index = machines.firstIndex(where: { $0.id == vm.id }) else { return }
        machines[index] = vm
        save()
    }

    func delete(id: UUID) {
        machines.removeAll { $0.id == id }
        save()
    }

    func setStatus(_ status: VMStatus, for id: UUID) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[index].status = status
        if status == .running {
            machines[index].lastBootedAt = Date()
        }
        save()
    }

    func importDiskImage(from sourceURL: URL) throws -> String {
        ensureDirectories()
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let originalName = sourceURL.lastPathComponent
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var destinationURL = diskImagesDirectory.appendingPathComponent(originalName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let uniqueName = ext.isEmpty ? "\(baseName)-\(stamp)" : "\(baseName)-\(stamp).\(ext)"
            destinationURL = diskImagesDirectory.appendingPathComponent(uniqueName)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL.path
    }

    var cachedDiskImagesCount: Int {
        (try? fileManager.contentsOfDirectory(atPath: diskImagesDirectory.path).count) ?? 0
    }

    func clearUnreferencedDiskImages() -> Int {
        let referencedPaths = Set(machines.map(\.diskImagePath).filter { !$0.isEmpty })
        guard let contents = try? fileManager.contentsOfDirectory(at: diskImagesDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for fileURL in contents where !referencedPaths.contains(fileURL.path) {
            if (try? fileManager.removeItem(at: fileURL)) != nil {
                removed += 1
            }
        }
        return removed
    }

    var totalAllocatedRAMMB: Int {
        machines.reduce(0) { $0 + $1.ramMB }
    }

    var activeCount: Int {
        machines.filter { $0.status == .running }.count
    }

    private static func seedDefaults() -> [VirtualMachine] {
        [
            VirtualMachine(
                name: "Alpine Edge ARM64",
                osPreset: .linux,
                mode: .virtualize,
                architecture: .arm64,
                cpuCores: 4,
                ramMB: 2048,
                storageGB: 24,
                renderer: .metal,
                networkMode: .nat,
                diskImagePath: "alpine-virt-3.21-aarch64.iso",
                customQEMUArgs: "-nographic -serial mon:stdio"
            ),
            VirtualMachine(
                name: "Windows 11 Workstation",
                osPreset: .windows,
                mode: .emulate,
                architecture: .x86_64,
                cpuCores: 4,
                ramMB: 4096,
                storageGB: 64,
                renderer: .angle,
                networkMode: .nat,
                diskImagePath: "win11_24h2_x64.qcow2",
                customQEMUArgs: "-cpu max,+avx2 -usb -device usb-tablet"
            )
        ]
    }
}

// MARK: - App Entry Point

@main
struct NexusVMApp: App {
    @State private var store = VMStore()
    @State private var jitDetector = JITDetector()
    @State private var settings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(jitDetector)
                .environment(settings)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        jitDetector.refresh(triggerHaptic: false)
                    }
                }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        if settings.autoPollJIT {
                            jitDetector.refresh(triggerHaptic: false)
                        }
                    }
                }
        }
    }
}

// MARK: - Root Navigation & Floating Glassmorphic Tab Bar

enum NexusTab: String, CaseIterable, Identifiable {
    case machines = "Machines"
    case create = "Create"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
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

    @State private var selectedTab: NexusTab = .machines
    @State private var activeConsoleVM: VirtualMachine?
    @State private var inspectedVM: VirtualMachine?

    var body: some View {
        ZStack(alignment: .bottom) {
            NexusTheme.background.ignoresSafeArea()

            Group {
                switch selectedTab {
                case .machines:
                    MachinesDashboardView(
                        onOpenConsole: { vm in
                            store.setStatus(.running, for: vm.id)
                            if let updated = store.machines.first(where: { $0.id == vm.id }) {
                                activeConsoleVM = updated
                            } else {
                                activeConsoleVM = vm
                            }
                        },
                        onInspectVM: { vm in
                            inspectedVM = vm
                        }
                    )
                case .create:
                    CreateVMWizardView { createdVM in
                        store.add(createdVM)
                        selectedTab = .machines
                    }
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FloatingGlassTabBar(selectedTab: $selectedTab) {
                settings.impact(.light)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .sheet(item: $inspectedVM) { vm in
            VMInspectorView(vm: vm) { launchedVM in
                inspectedVM = nil
                store.setStatus(.running, for: launchedVM.id)
                if let refreshed = store.machines.first(where: { $0.id == launchedVM.id }) {
                    activeConsoleVM = refreshed
                } else {
                    activeConsoleVM = launchedVM
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $activeConsoleVM) { vm in
            ActiveVMConsoleView(vm: vm)
        }
    }
}

struct FloatingGlassTabBar: View {
    @Binding var selectedTab: NexusTab
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(NexusTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        selectedTab = tab
                    }
                    onSelect()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(isSelected ? NexusTheme.background : NexusTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isSelected ? NexusTheme.cyan : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .background(NexusTheme.surface.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(NexusTheme.border.opacity(0.95), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 10)
    }
}

// MARK: - Live JIT Status Pill

struct JITStatusPill: View {
    @Environment(JITDetector.self) private var jitDetector
    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    jitDetector.refresh(triggerHaptic: true)
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(jitDetector.isJITActive ? NexusTheme.cyan : NexusTheme.amber)
                        .frame(width: 8, height: 8)
                        .shadow(
                            color: (jitDetector.isJITActive ? NexusTheme.cyan : NexusTheme.amber).opacity(0.8),
                            radius: 5
                        )

                    Text(jitDetector.isJITActive ? "JIT Active" : "Waiting for StikDebug")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(jitDetector.isJITActive ? NexusTheme.cyan : NexusTheme.amber)

                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(NexusTheme.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    (jitDetector.isJITActive ? NexusTheme.cyan : NexusTheme.amber).opacity(0.11)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            (jitDetector.isJITActive ? NexusTheme.cyan : NexusTheme.amber).opacity(0.38),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)

            Button {
                showDetails = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NexusTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .alert("csops() Kernel Status", isPresented: $showDetails) {
            Button("Refresh Now") {
                jitDetector.refresh(triggerHaptic: true)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "PID: \(jitDetector.pid)\n" +
                "Flags: \(jitDetector.hexFlags)\n" +
                "CS_DEBUGGED (0x10000000): \(jitDetector.isJITActive ? "SET" : "UNSET")\n" +
                "Checks: \(jitDetector.checkCount)"
            )
        }
    }
}

// MARK: - Machines Dashboard

struct MachinesDashboardView: View {
    @Environment(VMStore.self) private var store
    @Environment(AppSettings.self) private var settings

    let onOpenConsole: (VirtualMachine) -> Void
    let onInspectVM: (VirtualMachine) -> Void

    @State private var isGridView = true
    @State private var searchText = ""

    private var filteredMachines: [VirtualMachine] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.machines }
        return store.machines.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.architecture.rawValue.localizedCaseInsensitiveContains(query) ||
            $0.osPreset.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerSection
                    telemetryStrip
                    searchAndLayoutBar

                    if filteredMachines.isEmpty {
                        emptyStateView
                    } else if isGridView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 165), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(filteredMachines) { vm in
                                VMGridCard(
                                    vm: vm,
                                    onPlayPause: { handlePlayPause(vm) },
                                    onStop: { handleStop(vm) },
                                    onConsole: { onOpenConsole(vm) },
                                    onInspect: { onInspectVM(vm) },
                                    onDelete: { store.delete(id: vm.id) }
                                )
                            }
                        }
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredMachines) { vm in
                                VMListRow(
                                    vm: vm,
                                    onPlayPause: { handlePlayPause(vm) },
                                    onStop: { handleStop(vm) },
                                    onConsole: { onOpenConsole(vm) },
                                    onInspect: { onInspectVM(vm) },
                                    onDelete: { store.delete(id: vm.id) }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
            .background(NexusTheme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "cube.transparent.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(NexusTheme.cyan)
                    Text("NexusVM")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(NexusTheme.textPrimary)
                }
                Text("iOS 27 Hypervisor & QEMU Manager")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(NexusTheme.textSecondary)
            }
            Spacer()
            JITStatusPill()
        }
    }

    private var telemetryStrip: some View {
        HStack(spacing: 10) {
            TelemetryTile(
                label: "MACHINES",
                value: "\(store.machines.count)",
                accent: NexusTheme.textPrimary
            )
            TelemetryTile(
                label: "ACTIVE",
                value: "\(store.activeCount)",
                accent: store.activeCount > 0 ? NexusTheme.emerald : NexusTheme.textSecondary
            )
            TelemetryTile(
                label: "POOL RAM",
                value: String(format: "%.1fG", Double(store.totalAllocatedRAMMB) / 1024.0),
                accent: NexusTheme.cyan
            )
        }
    }

    private var searchAndLayoutBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(NexusTheme.textMuted)
                    .font(.system(size: 14))
                TextField("Filter VMs or architectures...", text: $searchText)
                    .font(.system(size: 14))
                    .foregroundStyle(NexusTheme.textPrimary)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NexusTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .nexusCard(cornerRadius: 12)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isGridView.toggle()
                }
                settings.impact(.light)
            } label: {
                Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NexusTheme.cyan)
                    .frame(width: 40, height: 38)
                    .nexusCard(cornerRadius: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle Grid or List Layout")
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(NexusTheme.textMuted)
            Text("No Virtual Machines Found")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NexusTheme.textPrimary)
            Text("Use the Create tab to configure a new Linux, Windows, macOS, or custom ISO guest.")
                .font(.system(size: 13))
                .foregroundStyle(NexusTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 20)
        .nexusCard()
    }

    private func handlePlayPause(_ vm: VirtualMachine) {
        settings.impact(.medium)
        switch vm.status {
        case .stopped, .paused:
            onOpenConsole(vm)
        case .running:
            store.setStatus(.paused, for: vm.id)
        }
    }

    private func handleStop(_ vm: VirtualMachine) {
        settings.impact(.light)
        store.setStatus(.stopped, for: vm.id)
    }
}

struct TelemetryTile: View {
    let label: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(NexusTheme.textMuted)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .nexusCard(cornerRadius: 12)
    }
}

struct VMGridCard: View {
    let vm: VirtualMachine
    let onPlayPause: () -> Void
    let onStop: () -> Void
    let onConsole: () -> Void
    let onInspect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(vm.osPreset.accentColor.opacity(0.14))
                        .frame(width: 38, height: 38)
                    Image(systemName: vm.osPreset.symbolName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(vm.osPreset.accentColor)
                }

                Spacer()

                StatusBadge(status: vm.status)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(vm.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NexusTheme.textPrimary)
                    .lineLimit(1)

                Text(vm.diskImageFileName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NexusTheme.textMuted)
                    .lineLimit(1)
            }

            FlowBadgeRow(vm: vm)

            Divider().overlay(NexusTheme.border)

            HStack(spacing: 8) {
                Button(action: onPlayPause) {
                    Image(systemName: vm.status == .running ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(NexusTheme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(vm.status == .running ? NexusTheme.amber : NexusTheme.cyan)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)

                if vm.status != .stopped {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NexusTheme.crimson)
                            .frame(width: 34, height: 32)
                            .background(NexusTheme.crimson.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onConsole) {
                    Image(systemName: "terminal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NexusTheme.textPrimary)
                        .frame(width: 34, height: 32)
                        .nexusCard(elevated: true, cornerRadius: 9)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .nexusCard(
            borderColor: vm.status == .running ? NexusTheme.emerald.opacity(0.45) : NexusTheme.border
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onInspect)
        .contextMenu {
            Button("Open Console", systemImage: "terminal", action: onConsole)
            Button("Inspect Hardware", systemImage: "wrench.and.screwdriver", action: onInspect)
            if vm.status != .stopped {
                Button("Stop VM", systemImage: "stop.circle", action: onStop)
            }
            Divider()
            Button("Delete VM", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

struct VMListRow: View {
    let vm: VirtualMachine
    let onPlayPause: () -> Void
    let onStop: () -> Void
    let onConsole: () -> Void
    let onInspect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(vm.osPreset.accentColor.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: vm.osPreset.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(vm.osPreset.accentColor)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(vm.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NexusTheme.textPrimary)
                        .lineLimit(1)
                    StatusBadge(status: vm.status)
                }

                HStack(spacing: 6) {
                    SpecChip(text: vm.architecture.rawValue, tint: NexusTheme.cyan)
                    SpecChip(text: "\(vm.cpuCores)C", tint: NexusTheme.textSecondary)
                    SpecChip(text: vm.formattedRAM, tint: NexusTheme.textSecondary)
                    SpecChip(text: vm.mode.rawValue, tint: NexusTheme.amber)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Button(action: onPlayPause) {
                    Image(systemName: vm.status == .running ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(NexusTheme.background)
                        .frame(width: 34, height: 34)
                        .background(vm.status == .running ? NexusTheme.amber : NexusTheme.cyan)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                if vm.status != .stopped {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NexusTheme.crimson)
                            .frame(width: 34, height: 34)
                            .background(NexusTheme.crimson.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onInspect) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NexusTheme.textMuted)
                        .frame(width: 24, height: 34)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .nexusCard(
            borderColor: vm.status == .running ? NexusTheme.emerald.opacity(0.45) : NexusTheme.border,
            cornerRadius: 14
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onInspect)
        .contextMenu {
            Button("Open Console", systemImage: "terminal", action: onConsole)
            Button("Inspect Hardware", systemImage: "wrench.and.screwdriver", action: onInspect)
            if vm.status != .stopped {
                Button("Stop VM", systemImage: "stop.circle", action: onStop)
            }
            Divider()
            Button("Delete VM", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

struct StatusBadge: View {
    let status: VMStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.badgeColor)
                .frame(width: 6, height: 6)
            Text(status.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(status.badgeColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status.badgeColor.opacity(0.14))
        .clipShape(Capsule())
    }
}

struct FlowBadgeRow: View {
    let vm: VirtualMachine

    var body: some View {
        HStack(spacing: 5) {
            SpecChip(text: vm.architecture.rawValue, tint: NexusTheme.cyan)
            SpecChip(text: "\(vm.cpuCores)C", tint: NexusTheme.textSecondary)
            SpecChip(text: vm.formattedRAM, tint: NexusTheme.textSecondary)
        }
    }
}

struct SpecChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(NexusTheme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(NexusTheme.border, lineWidth: 1)
            )
    }
}

// MARK: - Create VM Wizard

struct CreateVMWizardView: View {
    @Environment(VMStore.self) private var store
    @Environment(AppSettings.self) private var settings

    let onCreate: (VirtualMachine) -> Void

    @State private var step = 0
    @State private var name = "Linux Dev Guest"
    @State private var osPreset: OSPreset = .linux
    @State private var mode: ExecutionMode =
