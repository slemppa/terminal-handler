import SwiftUI
import THCore

extension JarvisController.Phase {
    var color: Color {
        switch self {
        case .idle: Color(white: 0.45)
        case .received: Dot.blue.color
        case .thinking: Dot.green.color
        case .speaking: Color(red: 0.38, green: 0.78, blue: 1.0)
        case .failed: Dot.orange.color
        }
    }

    var label: String {
        switch self {
        case .idle: "Valmis"
        case .received: "Vastaanotettu"
        case .thinking(let step): step.map { "Miettii · \($0)" } ?? "Miettii…"
        case .speaking: "Puhuu"
        case .failed: "Virhe"
        }
    }

    /// Short label for the collapsed pill.
    var pillLabel: String {
        switch self {
        case .idle: "Jarvis"
        case .received: "Kuulin"
        case .thinking: "Miettii"
        case .speaking: "Puhuu"
        case .failed: "Virhe"
        }
    }
}

/// The pill's Jarvis indicator while a command is in flight.
struct JarvisPillBadge: View {
    let jarvis: JarvisController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: animating)
            Text(jarvis.phase.pillLabel)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(jarvis.phase.color)
        .contentTransition(.opacity)
    }

    private var animating: Bool {
        guard !reduceMotion else { return false }
        switch jarvis.phase {
        case .thinking, .speaking, .received: return true
        default: return false
        }
    }
}

/// Jarvis's row in the open island: what was heard, what it is doing, what it answered.
struct JarvisCard: View {
    let jarvis: JarvisController

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(jarvis.phase.color)
                Text("Jarvis").font(.system(size: 13, weight: .semibold))
                Text(jarvis.phase.label)
                    .font(.system(size: 11))
                    .foregroundStyle(jarvis.phase == .idle ? .secondary : jarvis.phase.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if !jarvis.queued.isEmpty {
                    Text("+\(jarvis.queued.count) jonossa").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                if jarvis.isSpeaking {
                    Button("Hiljaa") { jarvis.stopSpeaking() }.buttonStyle(IslandButtonStyle())
                } else if jarvis.isBusy {
                    Button("Keskeytä") { jarvis.cancel() }.buttonStyle(IslandButtonStyle())
                }
            }
            if !jarvis.transcript.isEmpty {
                Text("”\(jarvis.transcript)”")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !jarvis.reply.isEmpty {
                ScrollView {
                    Text(jarvis.reply)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 14, style: .continuous))
        .contentShape(.rect)
        // A click anywhere on the card silences Satu.
        .onTapGesture { jarvis.stopSpeaking() }
    }
}
