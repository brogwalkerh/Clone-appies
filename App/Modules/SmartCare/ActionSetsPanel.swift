import SwiftUI
import CleanerCore
import DesignSystem
import PerformanceModule
import SmartCareModule

/// My Tools action sets on Smart Care (PLAN.md §3.12): one click runs a
/// saved sequence of cleanups and maintenance tasks.
struct ActionSetsPanel: View {
    @Environment(AppState.self) private var appState
    @State private var editing: ActionSet?
    @State private var pendingRun: ActionSet?

    var body: some View {
        let automation = appState.automation
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Action Sets", systemImage: "square.stack.3d.up")
                        .font(.headline)
                    Spacer()
                    Button("New Action Set") {
                        editing = ActionSet(name: "", steps: [])
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                ForEach(automation.actionSets) { set in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(set.name).font(.subheadline.weight(.semibold))
                            Text(ActionSetText.summary(set))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        if automation.runningSetID == set.id {
                            ProgressView().controlSize(.small)
                        }
                        Button("Edit") { editing = set }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .disabled(automation.isRunning)
                        Button("Run") { pendingRun = set }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(automation.isRunning)
                    }
                    if set.id != automation.actionSets.last?.id {
                        Divider()
                    }
                }
                if !automation.stepLines.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(automation.stepLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { set in
            ActionSetEditor(original: set) { editing = nil }
                .environment(appState)
        }
        .confirmationDialog("Run this action set?",
                            isPresented: Binding(get: { pendingRun != nil },
                                                 set: { if !$0 { pendingRun = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingRun) { set in
            Button("Run \(set.name)") {
                Task { await appState.automation.run(set) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Safe items move to the Trash (anything already in the Trash is deleted). Maintenance steps that need the helper fail if it is not installed.")
        }
        .messageAlert("Action sets", message: Binding(
            get: { appState.automation.lastError },
            set: { appState.automation.lastError = $0 }))
    }
}

/// Human-readable step lists, shared by the panel and the scheduler.
enum ActionSetText {
    static func summary(_ set: ActionSet) -> String {
        guard !set.steps.isEmpty else { return "No steps" }
        return set.steps.map(describe).joined(separator: " → ")
    }

    static func describe(_ step: ActionStep) -> String {
        switch step {
        case .clean(let ids, let includeCaution):
            let names = ids.map { id in scannerNames[id] ?? id }
            return "Clean " + names.joined(separator: ", ") + (includeCaution ? " (incl. caution)" : "")
        case .maintenance(let taskID):
            return MaintenanceCatalog.task(id: taskID)?.name ?? taskID
        }
    }

    static let scannerNames: [String: String] = Dictionary(
        AutomationState.allScanners().map { (type(of: $0).id, $0.displayName) },
        uniquingKeysWith: { first, _ in first })
}

/// Create or edit an action set. Saves as one cleaning step (every chosen
/// scanner) followed by the chosen maintenance tasks in catalog order.
struct ActionSetEditor: View {
    @Environment(AppState.self) private var appState
    let original: ActionSet
    let onDone: () -> Void

    @State private var name: String
    @State private var scannerIDs: Set<String>
    @State private var includeCaution: Bool
    @State private var taskIDs: Set<String>

    private struct ScannerChoice: Identifiable {
        let id: String
        let name: String
        let module: ModuleID
    }

    private let scanners: [ScannerChoice] = AutomationState.allScanners().map {
        ScannerChoice(id: type(of: $0).id, name: $0.displayName, module: $0.module)
    }

    init(original: ActionSet, onDone: @escaping () -> Void) {
        self.original = original
        self.onDone = onDone
        var ids: Set<String> = []
        var caution = false
        var tasks: Set<String> = []
        for step in original.steps {
            switch step {
            case .clean(let stepIDs, let stepCaution):
                ids.formUnion(stepIDs)
                caution = caution || stepCaution
            case .maintenance(let taskID):
                tasks.insert(taskID)
            }
        }
        _name = State(initialValue: original.name)
        _scannerIDs = State(initialValue: ids)
        _includeCaution = State(initialValue: caution)
        _taskIDs = State(initialValue: tasks)
    }

    private var draft: ActionSet {
        var steps: [ActionStep] = []
        let orderedIDs = scanners.map(\.id).filter { scannerIDs.contains($0) }
        if !orderedIDs.isEmpty {
            steps.append(.clean(scannerIDs: orderedIDs, includeCaution: includeCaution))
        }
        for task in MaintenanceCatalog.all where taskIDs.contains(task.id) {
            steps.append(.maintenance(taskID: task.id))
        }
        return ActionSet(id: original.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                         steps: steps, createdAt: original.createdAt)
    }

    var body: some View {
        let automation = appState.automation
        let problems = automation.problems(in: draft)
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Friday clean"))
                }
                ForEach(ModuleID.allCases, id: \.self) { module in
                    let choices = scanners.filter { $0.module == module }
                    if !choices.isEmpty {
                        Section("Clean: \(module.displayName)") {
                            ForEach(choices) { choice in
                                Toggle(choice.name, isOn: binding(for: choice.id, in: $scannerIDs))
                            }
                        }
                    }
                }
                Section {
                    Toggle("Also remove items marked Caution", isOn: $includeCaution)
                    Text("Items marked Risky are never removed by an action set.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Maintenance") {
                    ForEach(MaintenanceCatalog.all) { task in
                        Toggle(task.requiresHelper ? "\(task.name) (needs the helper)" : task.name,
                               isOn: binding(for: task.id, in: $taskIDs))
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if automation.isSaved(original) {
                    if automation.isPreset(original) {
                        Button("Revert to Default") {
                            automation.delete(original)
                            onDone()
                        }
                    } else {
                        Button("Delete", role: .destructive) {
                            automation.delete(original)
                            onDone()
                        }
                    }
                }
                if let problem = problems.first, !name.isEmpty || !draft.steps.isEmpty {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    automation.save(draft)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
    }

    private func binding(for id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { isOn in
                    if isOn { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
                })
    }
}
