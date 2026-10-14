import AppKit
import SwiftUI
import TickRestCore
import UniformTypeIdentifiers

struct BackgroundSettingsView<StyleSelection: View, AdditionalSettings: View>: View {
    @ObservedObject var model: AppController
    @ObservedObject var library: WallpaperLibrary
    @State private var screens: [NSScreen] = []
    @State private var selectedScreenID = ""
    @State private var refreshToken = 0
    @State private var resolvedSize: CGSize?
    @State private var usedFallback = false
    @State private var readFailure: WallpaperReadFailure?
    @State private var previewImage: CGImage?
    @State private var dragStart: BackgroundPoint?
    @State private var deleting: WallpaperItem?
    @State private var showingProtectionPreview = false
    private let styleSelection: StyleSelection
    private let additionalSettings: AdditionalSettings
    init(model: AppController, @ViewBuilder styleSelection: () -> StyleSelection,
         @ViewBuilder additionalSettings: () -> AdditionalSettings) {
        self.model = model; library = model.wallpapers
        self.styleSelection = styleSelection()
        self.additionalSettings = additionalSettings()
    }
    private var background: OverlayBackground { model.settings.overlayBackground.normalized }
    private var screen: NSScreen? {
        screens.first { ConnectedDisplay.identifier(for: $0) == selectedScreenID } ?? screens.first
    }
    private func binding<Value>(_ path: WritableKeyPath<OverlayBackground, Value>) -> Binding<Value> {
        Binding(get: { model.settings.overlayBackground[keyPath: path] }, set: { value in
            model.update(deferPersistence: true) { $0.overlayBackground[keyPath: path] = value; $0.overlayBackground = $0.overlayBackground.normalized }
        })
    }
    private var solid: Binding<SRGBColor> {
        Binding(get: { model.settings.overlayBackgroundColor }, set: { color in model.update(deferPersistence: true) { $0.overlayBackgroundColor = color } })
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    styleSelection
                        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
                    Section {
                        VStack(alignment: .leading, spacing: 20) {
                            SettingsSectionCard {
                                BackgroundMenuPicker(title: L10n.text("background.type"), selection: binding(\.kind),
                                                       choices: OverlayBackgroundKind.allCases) { L10n.text("background.type.\($0.rawValue)") }
                                Divider()
                                if background.kind != .solid {
                                    protectionControls
                                    Divider()
                                }
                                switch background.kind {
                                case .solid: SolidBackgroundEditor(color: solid)
                                case .gradient: GradientBackgroundEditor(gradient: binding(\.gradient))
                                case .wallpaper: wallpaperEditor
                                }
                            }
                            additionalSettings
                        }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 32)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } header: {
                        SettingsSectionCard {
                            previewPanel(height: min(220, max(110, geometry.size.height * 0.28)))
                        }
                        .padding(.horizontal, 20).padding(.bottom, 12)
                        // Keep the scrolling controls from showing through the pinned preview.
                        .background(Color(nsColor: SettingsPalette.content))
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.bordered)
        .onAppear { updateScreens() }
        .onDisappear { model.persist() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in updateScreens() }
        .onChange(of: background.wallpaper.source) { _ in clearWallpaperResolution(); startFirstSync() }
        .onChange(of: background.wallpaper.selectedID) { _ in clearWallpaperResolution() }
        .onChange(of: selectedScreenID) { _ in clearWallpaperResolution() }
        .onChange(of: background.kind) { _ in clearWallpaperResolution(); startFirstSync() }
        .alert(L10n.text("background.remove_title"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.text("common.cancel"), role: .cancel) { deleting = nil }
            Button(L10n.text("background.remove"), role: .destructive) {
                guard let item = deleting else { return }; deleting = nil
                Task {
                    if await library.remove(item.id), model.settings.overlayBackground.wallpaper.customID == item.id {
                        binding(\.wallpaper.customID).wrappedValue = nil
                    }
                }
            }
        } message: { Text(L10n.text("background.remove_help")) }
    }
    private func previewPanel(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(L10n.text("background.title")).font(.headline)
                    Spacer(minLength: 12)
                    footerActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("background.title")).font(.headline)
                    HStack(spacing: 16) { footerActions }
                }
            }
            if screens.count > 1 {
                Picker(L10n.text("background.preview_screen"), selection: $selectedScreenID) {
                    ForEach(screens, id: \.self) { Text($0.localizedName).tag(ConnectedDisplay.identifier(for: $0)) }
                }.pickerStyle(.menu).buttonStyle(.borderless)
            }
            Divider()
            preview(height: height)
        }
    }
    private var protectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            BackgroundNumberControl(title: L10n.text("background.protection_scope", protectionScope), value: Binding(
                get: { background.activeProtection * 100 },
                set: { binding(\.activeProtection).wrappedValue = $0 / 100 }), range: 0...100, step: 1, suffix: "%")
            Button { showingProtectionPreview.toggle() } label: {
                Label(L10n.text("background.protection_preview"), systemImage: "magnifyingglass").font(.caption)
            }
            .popover(isPresented: $showingProtectionPreview) {
                VStack(alignment: .leading, spacing: 12) {
                    BackgroundProtectionPreview(background: background, image: previewImage)
                    Text(L10n.text("background.protection_help")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(width: 320)
            }
        }
    }
    private var protectionScope: String {
        L10n.text(background.kind == .wallpaper ? "background.source.\(background.wallpaper.source.rawValue)" : "background.type.gradient")
    }
    private func clearWallpaperResolution() {
        resolvedSize = nil; usedFallback = false; readFailure = nil; previewImage = nil
    }
    private var footerActions: some View {
        Group {
            Button {
                let info = screen.map { ["screenID": ConnectedDisplay.identifier(for: $0)] }
                NotificationCenter.default.post(name: .previewRest, object: nil, userInfo: info)
            } label: { Text(L10n.text("background.full_preview")).fixedSize() }
                .disabled(model.engine.reminder != nil)
            Button {
                model.update { $0.overlayBackground = OverlayBackground(); $0.overlayBackgroundColor = Settings.defaultOverlayBackgroundColor }
            } label: { Text(L10n.text("background.reset")).fixedSize() }
        }
    }
    private func updateScreens() {
        screens = NSScreen.screens
        if !screens.contains(where: { ConnectedDisplay.identifier(for: $0) == selectedScreenID }) {
            let main = NSScreen.main ?? screens.first
            selectedScreenID = main.map { ConnectedDisplay.identifier(for: $0) } ?? ""
        }
        startFirstSync()
    }
    private func startFirstSync() {
        if background.kind == .wallpaper && background.wallpaper.source == .system && library.manifest.lastSync == nil && !library.busy {
            Task { await library.synchronize() }
        }
    }
    private func preview(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let virtual = screen?.frame.size ?? CGSize(width: 1440, height: 900)
                let scale = min(geometry.size.width / virtual.width, geometry.size.height / virtual.height)
                let size = CGSize(width: virtual.width * scale, height: virtual.height * scale)
                OverlayView(model: model, preview: true, primary: true, previewEnd: {}, wallpaperScreen: screen,
                            maximumImagePixels: 1200, backgroundRefreshToken: refreshToken,
                            onWallpaperResolved: { result in
                                resolvedSize = result.originalSize ?? result.image.map { CGSize(width: $0.width, height: $0.height) }
                                usedFallback = result.usedFallback
                                readFailure = result.failure; previewImage = result.image
                            })
                    .frame(width: virtual.width, height: virtual.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .clipped().allowsHitTesting(false)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2).onChanged { event in
                        if background.kind == .gradient && background.gradient.kind == .radial {
                            let offsetX = (geometry.size.width - size.width) / 2, offsetY = (geometry.size.height - size.height) / 2
                            binding(\.gradient.center).wrappedValue = BackgroundPoint(x: (event.location.x - offsetX) / size.width,
                                                                                     y: (event.location.y - offsetY) / size.height).normalized
                        } else if background.kind == .wallpaper, background.wallpaper.source != .desktop,
                                  background.wallpaper.fit == .fill, let image = resolvedSize {
                            if dragStart == nil { dragStart = background.wallpaper.position }
                            binding(\.wallpaper.position).wrappedValue = BackgroundGeometry.draggedPosition(
                                start: dragStart!, translation: event.translation, image: image, viewport: size)
                        }
                    }.onEnded { _ in dragStart = nil })
            }
            .frame(height: height)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(L10n.text("background.preview_label"))
            if background.kind == .gradient && background.gradient.kind == .radial {
                Text(L10n.text("background.drag_center")).font(.caption).foregroundStyle(.secondary)
            } else if background.kind == .wallpaper && background.wallpaper.source != .desktop && background.wallpaper.fit == .fill {
                Text(L10n.text("background.drag_image")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var wallpaperEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            BackgroundMenuPicker(title: L10n.text("background.wallpaper_source"), selection: binding(\.wallpaper.source),
                                   choices: WallpaperSource.allCases) { L10n.text("background.source.\($0.rawValue)") }
            Divider()
            if let warning = library.recoveryWarning {
                Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if background.wallpaper.source == .desktop {
                Text(L10n.text("background.desktop_help")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("background.refresh")) { refreshToken += 1 }
                if let failure = readFailure {
                    Text(L10n.text("background.desktop_failure", failure.message))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if usedFallback {
                    Text(L10n.text(previewImage == nil ? "background.default_fallback" : "background.cached_fallback"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if background.wallpaper.source == .system { systemControls }
                else {
                    Button(L10n.text("background.add")) { importImages() }.disabled(library.busy)
                    Text(L10n.text("background.import_help")).font(.caption).foregroundStyle(.secondary)
                }
                if library.busy {
                    HStack { ProgressView().controlSize(.small); Text(L10n.text("background.processing", library.scannedCount)).font(.caption) }
                }
                wallpaperGrid
                if let error = library.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if background.wallpaper.selectedID != nil && usedFallback {
                    Text(L10n.text("background.image_fallback")).font(.caption).foregroundStyle(.orange)
                }
                Divider()
                BackgroundMenuPicker(title: L10n.text("background.fit"), selection: binding(\.wallpaper.fit),
                                       choices: WallpaperFit.allCases) { L10n.text("background.fit.\($0.rawValue)") }
                Divider()
                BackgroundColorEditor(title: L10n.text("background.base_color"), color: binding(\.wallpaper.baseColor))
                if background.wallpaper.fit == .stretch {
                    Text(L10n.text("background.stretch_help")).font(.caption).foregroundStyle(.secondary)
                }
                if background.wallpaper.fit == .fill {
                    Divider()
                    BackgroundNumberControl(title: L10n.text("background.position_x"), value: percentBinding(\.wallpaper.position.x), range: 0...100, step: 1, suffix: "%")
                    BackgroundNumberControl(title: L10n.text("background.position_y"), value: percentBinding(\.wallpaper.position.y), range: 0...100, step: 1, suffix: "%")
                    Button(L10n.text("background.center")) { binding(\.wallpaper.position).wrappedValue = BackgroundPoint() }
                }
            }
            if let size = resolvedSize {
                let target = DesktopWallpaperSnapshot.pixelSize(screen)
                Text(L10n.text("background.dimensions", Int(size.width), Int(size.height), Int(target.width), Int(target.height)))
                    .font(.caption).foregroundStyle(.secondary)
                if isLowResolution(size, target: target) {
                    Text(L10n.text("background.low_resolution")).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
    private func percentBinding(_ path: WritableKeyPath<OverlayBackground, Double>) -> Binding<Double> {
        Binding(get: { background[keyPath: path] * 100 }, set: { binding(path).wrappedValue = $0 / 100 })
    }
    private func isLowResolution(_ size: CGSize, target: CGSize) -> Bool {
        let fit = background.wallpaper.fit
        if fit == .fit { return min(target.width / size.width, target.height / size.height) > 1.05 }
        return max(target.width / size.width, target.height / size.height) > 1.05
    }
    private var systemControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(L10n.text("background.sync")) { Task { await library.synchronize() } }.disabled(library.busy)
                Spacer()
                Text(L10n.text("background.sync_count", library.manifest.visibleItems(source: .system).count)).font(.caption).foregroundStyle(.secondary)
            }
            if let date = library.manifest.lastSync {
                Text(L10n.text("background.last_sync", date.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("background.system_help")).font(.caption).foregroundStyle(.secondary)
            Button(L10n.text("background.open_system")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") { NSWorkspace.shared.open(url) }
            }.buttonStyle(.link)
        }
    }
    private var wallpaperGrid: some View {
        let items = library.manifest.visibleItems(source: background.wallpaper.source)
        return Group {
            if items.isEmpty && !library.busy {
                Text(L10n.text(background.wallpaper.source == .system ? "background.system_empty" : "background.custom_empty"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if background.wallpaper.source == .system {
                            ForEach(SystemWallpaperCategory.allCases) { category in
                                let group = items.filter { $0.systemCategory == category }
                                if !group.isEmpty {
                                    Text(category.title).font(.headline)
                                    wallpaperThumbnails(group)
                                }
                            }
                        } else { wallpaperThumbnails(items) }
                    }
                }
                .scrollIndicators(.visible)
                .frame(height: items.count <= 2 ? 148 : 296)
                .clipped()
            }
        }
    }
    private func wallpaperThumbnails(_ items: [WallpaperItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 12)], spacing: 12) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Button {
                                    Task {
                                        if item.source == .system {
                                            if await library.selectSystem(item.id) { binding(\.wallpaper.systemID).wrappedValue = item.id }
                                        } else { binding(\.wallpaper.customID).wrappedValue = item.id }
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        WallpaperThumbnail(url: library.thumbnailURL(item.id), revision: library.revision)
                                            .frame(height: 72).frame(maxWidth: .infinity).clipped()
                                        Text(item.name).font(.caption).lineLimit(2).foregroundStyle(.primary)
                                        if item.available {
                                            Text("\(item.width) × \(item.height)").font(.caption2).foregroundStyle(.secondary)
                                        } else { Text(L10n.text("background.unavailable")).font(.caption2).foregroundStyle(.orange) }
                                    }.padding(6)
                                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                            background.wallpaper.selectedID == item.id ? Color.accentColor : .clear, lineWidth: 2))
                                }.buttonStyle(.plain).disabled(!item.available || library.busy)
                                    .accessibilityLabel(item.name)
                                    .accessibilityAddTraits(background.wallpaper.selectedID == item.id ? .isSelected : [])
                                if item.source == .custom {
                                    Button(L10n.text("background.remove"), role: .destructive) { deleting = item }
                                        .font(.caption).disabled(library.busy)
                                }
                            }
                        }
        }.padding(4).padding(.trailing, 12)
    }
    private func importImages() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.jpeg, .png, .heic, .heif, .tiff, .bmp, .webP]
        panel.title = L10n.text("background.add")
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task {
                if let id = await library.importImages(urls) {
                    binding(\.wallpaper.customID).wrappedValue = id
                }
            }
        }
    }
}

private struct WallpaperThumbnail: View {
    let url: URL?
    let revision: Int
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { ZStack { Color.secondary.opacity(0.08); Image(systemName: "photo").foregroundStyle(.secondary) } }
        }.task(id: "\(url?.path ?? "")-\(revision)") {
            let target = url
            let decoded = await Task.detached(priority: .utility) { target.flatMap { WallpaperRepository.decode($0, maximumPixels: 360) } }.value
            guard !Task.isCancelled else { return }; image = decoded
        }
    }
}

struct BackgroundColorEditor: View {
    let title: String
    @Binding var color: SRGBColor
    @State private var hex = ""
    @State private var invalid = false
    @FocusState private var hexFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title).fixedSize()
                    Spacer(minLength: 12)
                    colorInputs
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    colorInputs
                }
            }
            if invalid { Text(L10n.text("background.hex_error")).font(.caption).foregroundStyle(.red) }
        }.onAppear { hex = color.hexString }
            .onChange(of: color) { value in hex = value.hexString; invalid = false }
            .onChange(of: hexFocused) { focused in if !focused { commitHex() } }
    }
    private var colorInputs: some View {
        HStack(spacing: 8) {
            AnchoredColorPicker(selection: Binding(get: { color.swiftUIColor }, set: {
                if let value = SRGBColor(swiftUIColor: $0) { color = value }
            }), label: title).frame(width: 44, height: 22)
            TextField("#RRGGBB", text: $hex).font(.system(.body, design: .monospaced)).frame(width: 96)
                .labelsHidden()
                .focused($hexFocused)
                .accessibilityLabel(L10n.text("background.hex"))
                .onSubmit { commitHex() }
        }.fixedSize()
    }
    private func commitHex() {
        guard let value = SRGBColor.hex(hex) else { invalid = true; return }
        color = value; hex = value.hexString; invalid = false
    }
}

private struct SolidBackgroundEditor: View {
    @Binding var color: SRGBColor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92))], spacing: 10) {
                ForEach(BackgroundPresets.solid, id: \.name) { preset in
                    Button { color = preset.color } label: {
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 7).fill(preset.color.swiftUIColor).frame(height: 38)
                                .overlay { if color == preset.color { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white).shadow(color: .black, radius: 2) } }
                            Text(L10n.text("background.preset.\(preset.name)")).font(.caption).foregroundStyle(.primary)
                        }
                    }.buttonStyle(.plain).accessibilityAddTraits(color == preset.color ? .isSelected : [])
                }
            }
            Divider()
            BackgroundColorEditor(title: L10n.text("background.custom_color"), color: $color)
        }
    }
}

struct BackgroundNumberControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var suffix = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title).font(.callout).fixedSize()
                    Spacer(minLength: 12)
                    numberInput
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
                    numberInput
                }
            }
            ContinuousBackgroundSlider(value: $value, range: range, step: step, label: title)
                .frame(maxWidth: .infinity).frame(height: 22)
        }
    }
    private var numberInput: some View {
        HStack(spacing: 4) {
            Text(value, format: .number.precision(.fractionLength(0...1)))
                .monospacedDigit().frame(width: 65, alignment: .trailing)
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary).fixedSize() }
            Stepper(title, value: Binding(get: { value }, set: {
                value = $0.isFinite ? min(range.upperBound, max(range.lowerBound, $0)) : range.lowerBound
            }), in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
        }.fixedSize()
    }
}

/// Native dropdown with an explicit leading label and trailing selection.
struct BackgroundMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [Value]
    let label: (Value) -> String
    var body: some View {
        HStack(spacing: 20) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Picker(title, selection: $selection) {
                ForEach(choices, id: \.self) { Text(label($0)).tag($0) }
            }.pickerStyle(.menu).labelsHidden().fixedSize().buttonStyle(.borderless)
        }.frame(maxWidth: .infinity)
    }
}

private struct GradientBackgroundEditor: View {
    @Binding var gradient: BackgroundGradient
    @State private var selectedID: UUID?
    @State private var railDrag = GradientRailDrag()
    private var selected: BackgroundGradientStop? { gradient.stops.first { $0.id == selectedID } ?? gradient.stops.first }
    private func binding<Value>(_ path: WritableKeyPath<BackgroundGradient, Value>) -> Binding<Value> {
        Binding(get: { gradient[keyPath: path] }, set: {
            var next = gradient; next[keyPath: path] = $0; gradient = next.normalized
        })
    }
    private func editStop(_ action: (inout BackgroundGradientStop) -> Void) {
        guard let id = selected?.id, let index = gradient.stops.firstIndex(where: { $0.id == id }) else { return }
        var next = gradient; action(&next.stops[index]); gradient = next.normalized
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                ForEach(BackgroundPresets.gradients, id: \.name) { preset in
                    Button { gradient = preset.gradient; selectedID = gradient.stops.first?.id } label: {
                        VStack(spacing: 5) {
                            BackgroundGradientView(gradient: preset.gradient).frame(height: 38).clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay { if gradient.matches(preset.gradient) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white).shadow(color: .black, radius: 2) } }
                            Text(L10n.text("background.gradient_preset.\(preset.name)")).font(.caption).foregroundStyle(.primary)
                        }
                    }.buttonStyle(.plain)
                }
            }
            if !BackgroundPresets.gradients.contains(where: { gradient.matches($0.gradient) }) {
                Text(L10n.text("background.custom_gradient")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            BackgroundMenuPicker(title: L10n.text("background.gradient_type"), selection: binding(\.kind),
                                   choices: BackgroundGradientKind.allCases) { L10n.text("background.gradient.\($0.rawValue)") }
            Divider()
            colorRail
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { stopActions }
                VStack(alignment: .leading, spacing: 8) { stopActions }
            }
            Text(L10n.text("background.stops_help")).font(.caption).foregroundStyle(.secondary)
            Divider()
            if let stop = selected {
                BackgroundColorEditor(title: L10n.text("background.stop_color"), color: Binding(
                    get: { selected?.color ?? stop.color }, set: { value in editStop { $0.color = value } }))
                BackgroundNumberControl(title: L10n.text("background.stop_position"), value: Binding(
                    get: { (selected?.location ?? stop.location) * 100 }, set: { value in editStop { $0.location = value / 100 } }), range: 0...100, suffix: "%")
            }
            Divider()
            if gradient.kind == .linear {
                BackgroundNumberControl(title: L10n.text("background.angle"), value: binding(\.angle), range: 0...360, suffix: "°")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 8) {
                    ForEach([0.0, 45, 90, 135, 180, 270], id: \.self) { angle in
                        Button("\(Int(angle))°") { gradient.angle = angle }.font(.caption)
                    }
                }
            } else {
                BackgroundNumberControl(title: L10n.text("background.center_x"), value: Binding(
                    get: { gradient.center.x * 100 }, set: { gradient.center.x = $0 / 100 }), range: 0...100, suffix: "%")
                BackgroundNumberControl(title: L10n.text("background.center_y"), value: Binding(
                    get: { gradient.center.y * 100 }, set: { gradient.center.y = $0 / 100 }), range: 0...100, suffix: "%")
                BackgroundNumberControl(title: L10n.text("background.radius"), value: Binding(
                    get: { gradient.radius * 100 }, set: { gradient.radius = $0 / 100 }), range: 10...200, suffix: "%")
                Button(L10n.text("background.center")) { gradient.center = BackgroundPoint() }
            }
        }
    }
    private var stopActions: some View {
        Group {
            Button { addStop() } label: { Text(L10n.text("background.add_stop")).fixedSize() }
                .disabled(gradient.stops.count >= 5)
            Button {
                if let id = selected?.id {
                    var next = gradient; next.stops.removeAll { $0.id == id }
                    gradient = next.normalized; selectedID = gradient.stops.first?.id
                }
            } label: { Text(L10n.text("background.remove_stop")).fixedSize() }
                .disabled(gradient.stops.count <= 2)
            Button { var next = gradient; next.reverse(); gradient = next.normalized }
                label: { Text(L10n.text("background.reverse")).fixedSize() }
        }.buttonStyle(.bordered)
    }
    private var colorRail: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                LinearGradient(gradient: Gradient(stops: gradient.normalized.stops.map { .init(color: $0.color.swiftUIColor, location: $0.location) }),
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 22).clipShape(RoundedRectangle(cornerRadius: 5)).padding(.horizontal, 10)
                ForEach(gradient.stops) { stop in
                    Button { selectedID = stop.id } label: {
                        Circle().fill(stop.color.swiftUIColor).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .overlay(Circle().stroke(selected?.id == stop.id ? Color.accentColor : .black.opacity(0.4), lineWidth: 1))
                    }.buttonStyle(.plain)
                        .offset(x: stop.location * max(1, geometry.size.width - 20), y: 15)
                        .accessibilityLabel(L10n.text("background.stop_accessibility", Int(stop.location * 100)))
                        .accessibilityAdjustableAction { direction in
                            var next = gradient
                            guard let index = next.stops.firstIndex(where: { $0.id == stop.id }) else { return }
                            switch direction {
                            case .increment: next.stops[index].location += 0.01
                            case .decrement: next.stops[index].location -= 0.01
                            @unknown default: return
                            }
                            selectedID = stop.id; gradient = next.normalized
                        }
                }
            }
            .frame(width: geometry.size.width, height: 38)
            .contentShape(Rectangle())
            // Track on the stable rail, not on a button that moves/reorders as
            // normalized stops cross. Lock the stop ID for the whole gesture.
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { event in
                var next = gradient
                if let id = railDrag.update(gradient: &next, x: event.location.x,
                                            width: geometry.size.width, preferredID: selected?.id) {
                    selectedID = id; gradient = next
                }
            }.onEnded { _ in railDrag = GradientRailDrag() })
        }.frame(height: 38)
    }
    private func addStop() {
        guard gradient.stops.count < 5 else { return }
        let ordered = gradient.normalized.stops
        let pair = zip(ordered, ordered.dropFirst()).max { $0.1.location - $0.0.location < $1.1.location - $1.0.location }
        guard let pair else { return }
        let color = SRGBColor(red: (pair.0.color.red + pair.1.color.red) / 2,
                              green: (pair.0.color.green + pair.1.color.green) / 2,
                              blue: (pair.0.color.blue + pair.1.color.blue) / 2)
        let stop = BackgroundGradientStop(color: color, location: (pair.0.location + pair.1.location) / 2)
        var next = gradient; next.stops.append(stop); gradient = next.normalized; selectedID = stop.id
    }
}

/// A drag retains its original stop even when normalization reorders the array.
struct GradientRailDrag {
    private(set) var stopID: UUID?
    mutating func update(gradient: inout BackgroundGradient, x: CGFloat, width: CGFloat, preferredID: UUID?) -> UUID? {
        guard x.isFinite, width.isFinite, width > 20 else { return nil }
        let location = Double(min(1, max(0, (x - 10) / (width - 20))))
        if stopID == nil {
            stopID = gradient.stops.min { a, b in
                let first = abs(a.location - location), second = abs(b.location - location)
                if first == second { return a.id == preferredID && b.id != preferredID }
                return first < second
            }?.id
        }
        guard let id = stopID, let index = gradient.stops.firstIndex(where: { $0.id == id }) else { return nil }
        gradient.stops[index].location = location
        gradient = gradient.normalized
        return id
    }
}
