import AppKit
import SwiftUI

/// Makes learned fast paths inspectable and reversible. Built-in commands are
/// shown for orientation; only user-taught skills are editable or deletable.
private struct DesktopVoiceSkillsView: View {
    @ObservedObject var store: DesktopVoiceSkillStore
    @State private var editingSkill: DesktopVoiceLearnedSkill?
    @State private var deletingSkill: DesktopVoiceLearnedSkill?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice Control Skills")
                    .font(.title2.weight(.semibold))
                Text("Teach one by voice, then review its exact triggers and actions here.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            List {
                Section("Learned fast paths") {
                    if store.skills.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No learned skills yet")
                                .font(.headline)
                            Text("Try: “Learn a skill called Rescue tab. When I say rescue tab, press Command-Shift-T.”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(store.skills) { skill in
                            learnedRow(skill)
                        }
                    }
                }

                Section("Built-in fast paths (read-only)") {
                    ForEach(DesktopVoiceCommandRouter.fastPaths) { path in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(path.title).font(.headline)
                            Text(path.action).font(.caption).foregroundStyle(.secondary)
                            Text(path.examples.map { "“\($0)”" }.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .sheet(item: $editingSkill) { skill in
            DesktopVoiceSkillEditor(
                skill: skill,
                onSave: { updated in
                    do {
                        try store.update(
                            updated,
                            resolveApplication: { DesktopApplicationResolver.shared.resolve($0) }
                        )
                        editingSkill = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                },
                onCancel: { editingSkill = nil }
            )
        }
        .alert("Delete learned skill?", isPresented: Binding(
            get: { deletingSkill != nil },
            set: { if !$0 { deletingSkill = nil } }
        )) {
            Button("Cancel", role: .cancel) { deletingSkill = nil }
            Button("Delete", role: .destructive) {
                guard let skill = deletingSkill else { return }
                do {
                    try store.delete(id: skill.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
                deletingSkill = nil
            }
        } message: {
            Text("This removes “\(deletingSkill?.name ?? "this skill")” and all of its voice triggers.")
        }
        .alert("Couldn't save the skill", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func learnedRow(_ skill: DesktopVoiceLearnedSkill) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name).font(.headline)
                Text(skill.summary).font(.caption).foregroundStyle(.secondary)
                Text("Say: " + skill.triggers.map { "“\($0)”" }.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(skill.actions.map(\.readableDescription).joined(separator: "  →  "))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Edit") { editingSkill = skill }
                .controlSize(.small)
            Button {
                deletingSkill = skill
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete learned skill")
        }
        .padding(.vertical, 6)
    }
}

private struct DesktopVoiceSkillEditor: View {
    @State private var skill: DesktopVoiceLearnedSkill
    @State private var triggersText: String
    let onSave: (DesktopVoiceLearnedSkill) -> Void
    let onCancel: () -> Void

    init(
        skill: DesktopVoiceLearnedSkill,
        onSave: @escaping (DesktopVoiceLearnedSkill) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _skill = State(initialValue: skill)
        _triggersText = State(initialValue: skill.triggers.joined(separator: "\n"))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Learned Skill").font(.title2.weight(.semibold))

            LabeledContent("Name") {
                TextField("Skill name", text: $skill.name)
                    .frame(width: 380)
            }
            LabeledContent("Summary") {
                TextField("What this skill does", text: $skill.summary)
                    .frame(width: 380)
            }
            LabeledContent("Voice triggers") {
                TextEditor(text: $triggersText)
                    .font(.body)
                    .frame(width: 380, height: 76)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            }
            Text("One exact trigger phrase per line.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text("Ordered actions").font(.headline)
            ForEach($skill.actions) { $action in
                HStack {
                    Picker("", selection: $action.kind) {
                        ForEach(DesktopVoiceSkillActionKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    TextField(
                        action.kind == .openApplication ? "Application name" : "cmd+shift+t",
                        text: $action.value
                    )
                    Button {
                        skill.actions.removeAll { $0.id == action.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(skill.actions.count == 1)
                }
            }
            Button("Add Action", systemImage: "plus") {
                guard skill.actions.count < 8 else { return }
                skill.actions.append(DesktopVoiceSkillActionSpec(kind: .shortcut, value: "cmd+t"))
            }
            .controlSize(.small)

            Spacer()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    skill.triggers = triggersText.components(separatedBy: .newlines)
                    onSave(skill)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 590, height: 430)
    }
}

final class DesktopVoiceSkillsWindowController {
    static let shared = DesktopVoiceSkillsWindowController()

    private let window: NSWindow

    private init() {
        let hosting = NSHostingController(rootView: DesktopVoiceSkillsView(store: .shared))
        window = NSWindow(contentViewController: hosting)
        window.title = "BtrVoice Voice Control Skills"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 580))
        window.minSize = NSSize(width: 620, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
