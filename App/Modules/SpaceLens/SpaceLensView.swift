import AppKit
import SwiftUI
import CleanerCore
import SpaceLens
import DesignSystem

// MARK: - Model

/// Owns the size tree, the breadcrumb path, and the current bubble layout.
/// Layout runs off the main actor via `Task.detached`; results are tagged with a
/// generation so a stale layout never overwrites a newer one.
@MainActor
@Observable
final class SpaceLensModel {
    private(set) var root: SizeNode?
    /// Breadcrumb trail; `last` is the node whose children are displayed.
    private(set) var path: [SizeNode] = []
    private(set) var bubbles: [Bubble] = []
    private(set) var isBuilding = false
    private(set) var isLayingOut = false
    private(set) var errorMessage: String?
    private(set) var canvasSize: CGSize = .zero

    var hovered: Bubble?
    var rootURL: URL = FileManager.default.homeDirectoryForCurrentUser

    private let layout = CirclePackingLayout(padding: 2, minRadius: 3)
    private var layoutGeneration = 0

    var current: SizeNode? { path.last }

    func clearError() {
        errorMessage = nil
    }

    // MARK: Tree

    func build(root url: URL) async {
        isBuilding = true
        errorMessage = nil
        hovered = nil
        defer { isBuilding = false }
        do {
            let builder = SizeTreeBuilder(fileSystem: LocalFileSystem())
            let node = try await builder.build(root: url, maxDepth: 4)
            rootURL = url
            root = node
            path = [node]
            await relayout()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func zoom(into node: SizeNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        path.append(node)
        hovered = nil
        Task { await relayout() }
    }

    func pop(to index: Int) {
        guard index >= 0, index < path.count - 1 else { return }
        path.removeSubrange((index + 1)...)
        hovered = nil
        Task { await relayout() }
    }

    func popOne() {
        pop(to: path.count - 2)
    }

    // MARK: Layout

    func updateCanvasSize(_ size: CGSize) {
        guard size != canvasSize else { return }
        canvasSize = size
        Task { await relayout() }
    }

    func relayout() async {
        guard let node = current, canvasSize.width > 0, canvasSize.height > 0 else {
            bubbles = []
            return
        }
        layoutGeneration += 1
        let generation = layoutGeneration
        let layout = self.layout
        let radius = Double(min(canvasSize.width, canvasSize.height) / 2 - 12)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        isLayingOut = true
        let result = await Task.detached(priority: .userInitiated) {
            layout.layout(node, in: radius, center: center, maxDepth: 2)
        }.value
        guard generation == layoutGeneration else { return }
        // Parents first so children draw on top and hit-testing (reversed) finds the deepest.
        bubbles = result.sorted { $0.depth < $1.depth }
        isLayingOut = false
    }

    /// Deepest bubble under `point`, if any.
    func bubble(at point: CGPoint) -> Bubble? {
        bubbles.reversed().first { bubble in
            let dx = point.x - bubble.center.x
            let dy = point.y - bubble.center.y
            return dx * dx + dy * dy <= bubble.radius * bubble.radius
        }
    }

    // MARK: File actions

    func reveal(_ node: SizeNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.id])
    }

    /// Moves the item to the Trash via `FileManager.trashItem` (never permanent),
    /// then rebuilds the tree from the current root.
    func trash(_ node: SizeNode) async {
        guard !ProtectedPaths.default.isProtected(node.id) else {
            errorMessage = "\(node.name) is a protected system location."
            return
        }
        do {
            try FileManager.default.trashItem(at: node.id, resultingItemURL: nil)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await build(root: rootURL)
    }
}

// MARK: - View

/// Interactive bubble map (PLAN.md §3.9): click to zoom, breadcrumbs to go back,
/// hover for name and size, right-click to reveal or trash.
struct SpaceLensView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = SpaceLensModel()
    @State private var trashCandidate: SizeNode?

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider()
            content
        }
        .navigationTitle("Space Lens")
        .navigationSubtitle(model.rootURL.path(percentEncoded: false))
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button("Back", systemImage: "chevron.left") { model.popOne() }
                    .disabled(model.path.count < 2)
                Button("Choose Folder…", systemImage: "folder") { chooseFolder() }
                    .disabled(model.isBuilding)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomActionBar {
                PrimaryActionButton(model.root == nil ? "Scan Home Folder" : "Rescan",
                                    isLoading: model.isBuilding) {
                    Task { await model.build(root: model.rootURL) }
                }
            }
        }
        .confirmationDialog(
            "Move \"\(trashCandidate?.name ?? "")\" to the Trash?",
            isPresented: Binding(get: { trashCandidate != nil },
                                 set: { if !$0 { trashCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let node = trashCandidate {
                    Task { await model.trash(node) }
                }
                trashCandidate = nil
            }
            Button("Cancel", role: .cancel) { trashCandidate = nil }
        } message: {
            if let node = trashCandidate {
                Text("\(ByteFormatter.string(node.sizeBytes)) will be moved to the Trash. You can restore it from there.")
            }
        }
        .alert("Space Lens", isPresented: Binding(get: { model.errorMessage != nil },
                                                set: { if !$0 { model.clearError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if model.isBuilding, model.root == nil {
            EmptyState.scanning("Measuring \(model.rootURL.lastPathComponent)…",
                                message: "Folder sizes are summed up to four levels deep.")
        } else if model.root == nil {
            if appState.permissions.fullDiskAccess == .denied {
                EmptyState.needsPermission(
                    "Full Disk Access",
                    message: "Some folders will show as empty until Full Disk Access is granted. You can still scan.") {
                    PermissionChecker.openSystemSettings(for: .fullDiskAccess)
                }
            } else {
                EmptyState(title: "Space Lens",
                           message: "See your disk as bubbles sized by content. Click a bubble to zoom in, right-click to reveal or trash.",
                           style: .symbol("circle.hexagongrid"))
            }
        } else {
            bubbleCanvas
        }
    }

    // MARK: Breadcrumbs

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            if model.path.isEmpty {
                Text(model.rootURL.lastPathComponent)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(model.path.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button(node.name.isEmpty ? node.id.path(percentEncoded: false) : node.name) {
                    model.pop(to: index)
                }
                .buttonStyle(.plain)
                .fontWeight(index == model.path.count - 1 ? .semibold : .regular)
                .foregroundStyle(index == model.path.count - 1
                                 ? HierarchicalShapeStyle.primary
                                 : HierarchicalShapeStyle.secondary)
                .disabled(index == model.path.count - 1)
            }
            Spacer()
            if let current = model.current {
                Text(ByteFormatter.string(current.sizeBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            if model.isLayingOut {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .animation(reduceMotion ? nil : .default, value: model.path.count)
    }

    // MARK: Canvas

    private var bubbleCanvas: some View {
        ZStack(alignment: .topLeading) {
            Canvas(rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    model.hovered = model.bubble(at: point)
                case .ended:
                    model.hovered = nil
                }
            }
            .onTapGesture { location in
                if let bubble = model.bubble(at: location) {
                    // TODO(macOS27): animate the zoom with matchedGeometryEffect once
                    // bubbles are individual views; Canvas re-layout is instant for now.
                    model.zoom(into: bubble.node)
                }
            }
            .contextMenu {
                if let bubble = model.hovered {
                    Text(bubble.node.name)
                    Divider()
                    Button("Reveal in Finder") { model.reveal(bubble.node) }
                    if bubble.node.isDirectory, !bubble.node.children.isEmpty {
                        Button("Zoom In") { model.zoom(into: bubble.node) }
                    }
                    Button("Move to Trash", role: .destructive) { trashCandidate = bubble.node }
                }
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                model.updateCanvasSize(newSize)
            }
            .accessibilityLabel(Text("Bubble map of \(model.current?.name ?? "folder")"))

            if let hovered = model.hovered {
                tooltip(for: hovered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let folderTint = ModuleTint.accent.color(for: scheme, contrast: contrast)
        let fileTint = ModuleTint.clutter.color(for: scheme, contrast: contrast)
        let label = Color.primary
        let hoveredID = model.hovered?.id

        for bubble in model.bubbles {
            let rect = CGRect(x: bubble.center.x - bubble.radius,
                              y: bubble.center.y - bubble.radius,
                              width: bubble.radius * 2,
                              height: bubble.radius * 2)
            let path = Path(ellipseIn: rect)
            let base = bubble.node.isDirectory ? folderTint : fileTint
            let isHovered = bubble.id == hoveredID
            let opacity = (bubble.depth <= 1 ? 0.28 : 0.5) + (isHovered ? 0.2 : 0)

            context.fill(path, with: .color(base.opacity(opacity)))
            context.stroke(path,
                           with: .color(isHovered ? base : base.opacity(0.6)),
                           lineWidth: isHovered ? 2 : 0.75)

            if bubble.radius >= 26 {
                let fontSize = min(13, max(9, bubble.radius / 3.5))
                let name = Text(bubble.node.name)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(label)
                context.draw(name, at: CGPoint(x: bubble.center.x, y: bubble.center.y - (bubble.radius >= 44 ? fontSize * 0.7 : 0)))
                if bubble.radius >= 44 {
                    let sizeText = Text(ByteFormatter.string(bubble.node.sizeBytes))
                        .font(.system(size: fontSize * 0.85, design: .rounded))
                        .foregroundStyle(label.opacity(0.7))
                    context.draw(sizeText, at: CGPoint(x: bubble.center.x, y: bubble.center.y + fontSize * 0.8))
                }
            }
        }
    }

    private func tooltip(for bubble: Bubble) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bubble.node.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(ByteFormatter.string(bubble.node.sizeBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
            if bubble.node.isDirectory {
                Text("\(bubble.node.children.count) items")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
        .frame(maxWidth: 260)
        .offset(x: min(bubble.center.x + 14, max(0, model.canvasSize.width - 260)),
                y: max(0, bubble.center.y - bubble.radius - 60))
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.rootURL
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.build(root: url) }
    }
}

#Preview {
    SpaceLensView()
        .environment(AppState())
        .frame(width: 1000, height: 760)
}
