import SwiftUI

struct ContentView: View {
    @Bindable var session: Session
    @State private var showSettings = false
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 8)
                statusText
                transcript
                Spacer(minLength: 8)
                if case .prompt(let question, let options) = session.phase {
                    PromptCard(question: question, options: options) { session.choose($0) }
                } else {
                    MicButton(phase: session.phase) { session.mainButton() }
                }
                if session.isBusy {
                    Button("Lopeta", role: .cancel) { session.cancel() }
                        .foregroundStyle(.secondary)
                }
                if !typing { history }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { typing = false }
            .safeAreaInset(edge: .bottom) { composer }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Jarvis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { session.showScreen = true } label: { Image(systemName: "display") }
                        .accessibilityLabel("Macin ruutu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $session.showScreen) { ScreenView() }
            .onAppear { if Settings.client == nil { showSettings = true } }
        }
    }

    /// Type instead of talking: the answer comes back as text, not speech.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Kirjoita viesti", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .submitLabel(.send)
                .onChange(of: draft) { _, new in
                    // Return sends; a multi-line field would otherwise add a newline.
                    if new.last == "\n" {
                        draft.removeLast()
                        sendDraft()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.1)))
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
            }
            .disabled(!canSend)
            .accessibilityLabel("Lähetä")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black)
    }

    private var canSend: Bool {
        !session.isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        if session.send(draft) {
            draft = ""
            typing = false
        }
    }

    private var statusText: some View {
        Text(session.phase.label)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(session.phase.color)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: session.phase.label)
    }

    @ViewBuilder private var transcript: some View {
        VStack(spacing: 14) {
            if !session.heard.isEmpty {
                Text("”\(session.heard)”")
                    .font(.system(size: 20, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
            }
            if !session.reply.isEmpty {
                ScrollView {
                    Text(session.reply)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 260)
            }
            if case .failed(let message) = session.phase, session.reply != message {
                Text(message).font(.system(size: 15)).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder private var history: some View {
        if !session.history.isEmpty, !session.isBusy {
            List(session.history.dropFirst()) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.command).font(.system(size: 14, weight: .semibold))
                    Text(entry.reply).font(.system(size: 13)).foregroundStyle(entry.failed ? .red : .secondary).lineLimit(2)
                }
                .listRowBackground(Color.white.opacity(0.06))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: 180)
        }
    }
}

struct MicButton: View {
    let phase: Session.Phase
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(phase.color.opacity(0.18))
                    .frame(width: 190, height: 190)
                    .scaleEffect(pulse && phase.animates ? 1.12 : 1)
                Circle()
                    .fill(phase.color.gradient)
                    .frame(width: 140, height: 140)
                Image(systemName: phase.icon)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.black)
            }
        }
        .buttonStyle(PressStyle())
        .disabled(!phase.tappable)
        .sensoryFeedback(.impact, trigger: phase.label)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel(phase.label)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

struct PromptCard: View {
    let question: String
    let options: [String]
    let choose: (String) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(question)
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            ForEach(options, id: \.self) { option in
                Button { choose(option) } label: {
                    Text(option)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .tint(option == "Kiellä" ? .red : option == "Salli" ? .green : .orange)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.08)))
    }
}

extension Session.Phase {
    var label: String {
        switch self {
        case .idle: "Paina ja puhu tai kirjoita"
        case .listening: "Kuuntelen…"
        case .sending: "Lähetän Macille…"
        case .working(let step): step.map { "Miettii · \($0)" } ?? "Miettii…"
        case .prompt: "Jarvis kysyy"
        case .speaking: "Puhuu · paina hiljentääksesi"
        case .failed: "Jokin meni pieleen"
        }
    }

    var color: Color {
        switch self {
        case .idle: .cyan
        case .listening: .orange
        case .sending, .working: .green
        case .prompt: .orange
        case .speaking: .blue
        case .failed: .red
        }
    }

    var icon: String {
        switch self {
        case .idle, .failed: "mic.fill"
        case .listening: "waveform"
        case .sending, .working: "ellipsis"
        case .prompt: "questionmark"
        case .speaking: "speaker.wave.2.fill"
        }
    }

    var animates: Bool {
        switch self {
        case .listening, .sending, .working, .speaking: true
        default: false
        }
    }

    var tappable: Bool {
        switch self {
        case .idle, .failed, .listening, .speaking: true
        default: false
        }
    }
}
