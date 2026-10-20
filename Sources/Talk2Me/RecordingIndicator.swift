import AppKit
import SwiftUI

/// What the pill at the top of the screen shows. Kept apart from DictationController so
/// level updates (about ten per second) redraw only the pill, not every settings view.
@MainActor
final class IndicatorModel: ObservableObject {
    static let barCount = 9

    @Published var phase: DictationController.Phase = .idle
    @Published var isHandsFree = false
    @Published var levels = [Float](repeating: 0, count: barCount)
    @Published var startedAt = Date()
}

/// A floating pill at the top center of the screen, so you can see that Talk2Me is listening
/// and what it is doing next. It never takes focus, so the paste still reaches your app.
@MainActor
final class RecordingIndicator {
    private let model = IndicatorModel()
    private let panel: NSPanel
    private let size = NSSize(width: 260, height: 52)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: IndicatorView(model: model))
    }

    func update(phase: DictationController.Phase, isHandsFree: Bool) {
        if phase == .recording, model.phase != .recording {
            model.startedAt = Date()
            model.levels = [Float](repeating: 0, count: IndicatorModel.barCount)
        }
        if model.phase != phase { model.phase = phase }
        if model.isHandsFree != isHandsFree { model.isHandsFree = isHandsFree }
        phase == .idle ? hide() : show()
    }

    func push(level: Float) {
        guard model.phase == .recording else { return }
        model.levels.removeFirst()
        model.levels.append(level)
    }

    private func show() {
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        if !panel.isVisible {
            placeOnActiveScreen()
            panel.alphaValue = 0
            // orderFrontRegardless shows the panel without activating Talk2Me.
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new dictation may have started while the pill faded out.
                guard let self, self.model.phase == .idle else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// The screen with the focused window, just under the menu bar (and the notch).
    private func placeOnActiveScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: visible.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

private struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .recording:
            Circle().fill(.red).frame(width: 8, height: 8)
            LevelBars(levels: model.levels)
            Text(model.startedAt, style: .timer).monospacedDigit()
            if model.isHandsFree {
                Text("⏎ finish · esc discard").foregroundStyle(.white.opacity(0.6))
            }
        case .transcribing:
            status("waveform", "Transcribing…")
        case .cleaning:
            status("sparkles", "Cleaning up…")
        case .inserting:
            status("text.cursor", "Pasting…")
        case .idle:
            EmptyView()
        }
    }

    private func status(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).symbolEffect(.pulse)
            Text(text)
        }
    }
}

private struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 3 + CGFloat(levels[index]) * 15)
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}
