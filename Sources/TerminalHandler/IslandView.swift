import SwiftUI
import THCore

/// Clicks land on the first try even though the panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension Dot {
    var color: Color {
        switch self {
        case .orange: Color(red: 1.0, green: 0.62, blue: 0.04)
        case .blue: Color(red: 0.04, green: 0.52, blue: 1.0)
        case .green: Color(red: 0.19, green: 0.82, blue: 0.35)
        case .dimGreen: Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.45)
        case .grey: Color(white: 0.32)
        }
    }
}

struct DotView: View {
    var dot: Dot
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(dot.color)
            .frame(width: size, height: size)
            .shadow(color: dot == .orange ? dot.color.opacity(0.9) : .clear, radius: 4)
    }
}

struct IslandView: View {
    let model: AppModel
    let state: IslandState
    let controller: IslandController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var radius: CGFloat { state.expanded ? 22 : IslandState.pillHeight / 2 }
    private var edge: UnitPoint { state.opensDownward ? .top : .bottom }

    var body: some View {
        VStack(spacing: 0) {
            if !state.opensDownward { Spacer(minLength: 0) }
            Group {
                if state.expanded {
                    ExpandedContent(model: model, state: state, controller: controller)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: edge)))
                } else {
                    PillContent(model: model)
                        .frame(height: IslandState.pillHeight)
                        .contentShape(.capsule)
                        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                            .onChanged { _ in controller.dragChanged() }
                            .onEnded { _ in controller.dragEnded() })
                        .transition(.opacity)
                }
            }
            .background(.black, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(state.expanded ? 0.35 : 0.25), radius: state.expanded ? 18 : 6, y: state.expanded ? 8 : 2)
            .scaleEffect(state.dragging ? 1.06 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.islandFrame = $0 }
            .contextMenu { IslandMenu(model: model) }
            if state.opensDownward { Spacer(minLength: 0) }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 1.0), value: state.expanded)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: state.dragging)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0), value: model.rows)
    }
}

// MARK: - Pill

private struct PillContent: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if model.rows.isEmpty {
                DotView(dot: .grey)
            } else {
                ForEach(model.rows) { DotView(dot: $0.dot) }
            }
            if model.waitingCount > 0 {
                Text("\(model.waitingCount) odottaa")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Dot.orange.color)
                    .padding(.leading, 3)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 64)
    }
}

// MARK: - Expanded

private struct ExpandedContent: View {
    let model: AppModel
    let state: IslandState
    let controller: IslandController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let request = model.pending.first {
                QuestionCard(model: model, request: request, queued: model.pending.count - 1, controller: controller)
                    .id(request.id)
            }
            if model.rows.isEmpty {
                Text("Ei avoimia Ghostty-terminaaleja")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        TerminalRowView(row: row, shortcut: index < 9 ? index + 1 : nil, keyboardMode: state.keyboardMode) {
                            controller.jump(to: row.id)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 400)
    }
}

private struct TerminalRowView: View {
    let row: TerminalRow
    let shortcut: Int?
    let keyboardMode: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                DotView(dot: row.dot, size: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.repo)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let branch = row.branch {
                            Text(branch)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Text(row.activity)
                        .font(.system(size: 11))
                        .foregroundStyle(row.dot == .orange ? Dot.orange.color : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if let shortcut {
                    Text("⌘\(shortcut)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(keyboardMode ? .secondary : .tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
            .background(hovering ? Color.white.opacity(0.08) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Question

private struct QuestionCard: View {
    let model: AppModel
    let request: PendingRequest
    let queued: Int
    let controller: IslandController

    var body: some View {
        let row = model.row(forTTY: request.tty)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                DotView(dot: .orange, size: 8)
                Text(row?.repo ?? "Claude").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let branch = row?.branch {
                    Text(branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if queued > 0 {
                    Text("+\(queued) jonossa").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            switch request.kind {
            case .permission(let tool, let detail):
                PermissionBody(tool: tool, detail: detail) { answer in
                    model.answer(request.id, with: answer)
                } open: { open() }
            case .question(let questions):
                QuestionBody(questions: questions) { answers in
                    model.answer(request.id, with: .choices(answers))
                } open: { open() }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 14, style: .continuous))
    }

    private func open() {
        model.openTerminal(for: request)
        controller.collapse()
    }
}

private struct PermissionBody: View {
    let tool: String
    let detail: String
    let decide: (Answer) -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tool == "Bash" ? "Saako Claude ajaa komennon?" : "Saako Claude käyttää työkalua \(tool)?")
                .font(.system(size: 13))
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 8, style: .continuous))
            HStack(spacing: 6) {
                Button("Salli") { decide(.allow) }.buttonStyle(IslandButtonStyle(prominent: true))
                Button("Kiellä") { decide(.deny) }.buttonStyle(IslandButtonStyle())
                Spacer()
                Button("Avaa ikkuna ↗", action: open).buttonStyle(IslandButtonStyle())
            }
        }
    }
}

private struct QuestionBody: View {
    let questions: [AskQuestion]
    let submit: ([String: String]) -> Void
    let open: () -> Void
    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var selected: Set<String> = []

    var body: some View {
        if let question = questions[safe: index] {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if !question.header.isEmpty {
                        Text(question.header.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if questions.count > 1 {
                        Text("\(index + 1)/\(questions.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Text(question.question).font(.system(size: 13))
                VStack(spacing: 4) {
                    ForEach(question.options, id: \.self) { option in
                        OptionButton(option: option, selected: selected.contains(option.label)) {
                            choose(option.label, in: question)
                        }
                    }
                }
                HStack(spacing: 6) {
                    if question.multiSelect {
                        Button("Valmis") { commit(question) }
                            .buttonStyle(IslandButtonStyle(prominent: true))
                            .disabled(selected.isEmpty)
                    }
                    Spacer()
                    Button("Avaa ikkuna ↗", action: open).buttonStyle(IslandButtonStyle())
                }
            }
        } else {
            HStack {
                Text("Claude kysyy jotain, mitä ei voi näyttää tässä.").font(.system(size: 12))
                Spacer()
                Button("Avaa ikkuna ↗", action: open).buttonStyle(IslandButtonStyle())
            }
        }
    }

    private func choose(_ label: String, in question: AskQuestion) {
        if question.multiSelect {
            if selected.contains(label) { selected.remove(label) } else { selected.insert(label) }
        } else {
            selected = [label]
            commit(question)
        }
    }

    private func commit(_ question: AskQuestion) {
        let labels = question.options.map(\.label).filter(selected.contains)
        answers[question.question] = labels.joined(separator: ", ")
        selected = []
        if index + 1 < questions.count {
            index += 1
        } else {
            submit(answers)
        }
    }
}

private struct OptionButton: View {
    let option: AskOption
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label).font(.system(size: 12, weight: .medium))
                if !option.description.isEmpty {
                    Text(option.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(.rect)
            .background(
                selected ? Dot.blue.color.opacity(0.35) : Color.white.opacity(hovering ? 0.14 : 0.08),
                in: .rect(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Styles & menu

/// Instant press feedback, as on the pointer-down.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct IslandButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(prominent ? Dot.blue.color : Color.white.opacity(0.13), in: .rect(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct IslandMenu: View {
    let model: AppModel

    var body: some View {
        if HookSetup.isInstalled {
            Button("Poista Claude-hookit") { HookSetup.uninstall() }
        } else {
            Button("Asenna Claude-hookit…") { HookSetup.offerInstall(force: true) }
        }
        Divider()
        Button("Lopeta Terminal Handler") {
            model.releaseEverything()
            NSApp.terminate(nil)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
