import SwiftUI
import AVKit

// MARK: - Dolphin Protocol (Full-Screen Cinematic Boot Sequence)

private enum DolphinStage: Int, CaseIterable {
    case glitch
    case home
    case traffic
    case walls
    case observer
    case swimming
    case frequency
    case realization
    case protocol_
    case invitation

    var duration: Double {
        switch self {
        case .home: return 6.0
        case .glitch: return 0
        case .traffic: return 4.0
        case .walls: return 5.0
        case .observer: return 4.0
        case .swimming: return 6.0
        case .frequency: return 6.0
        case .realization: return 16.0
        case .protocol_: return 8.0
        case .invitation: return 0
        }
    }
}

private enum ProtocolPhase {
    case cinematic   // full-screen stage sequence
    case bios        // terminal boot window
}

public struct DolphinProtocolView: View {
    @Binding var isPresented: Bool
    let skipBios: Bool
    @State private var phase: ProtocolPhase = .cinematic
    @State private var currentStage: DolphinStage = .glitch
    @State private var stageOpacity: Double = 0
    @State private var sequenceComplete = false
    @State private var sequenceGeneration = 0
    @State private var glitchOffset: CGFloat = 0
    @State private var textGlow: CGFloat = 10
    @State private var eyeScaleY: CGFloat = 1.0
    @State private var dissolveOffset: CGFloat = -1.0
    @State private var cursorVisible = true
    @State private var revealedLines: Int = 0
    @State private var heartbeatScale: CGFloat = 1.0
    @State private var bugPulse: CGFloat = 10

    // BIOS state
    @State private var biosVisible = false
    @State private var visibleBootLines = 0
    @State private var biosComplete = false
    @State private var revealedBiosSuffixes: Set<Int> = []

    public init(isPresented: Binding<Bool>, skipBios: Bool = false) {
        self._isPresented = isPresented
        self.skipBios = skipBios
    }

    @FocusState private var isFocused: Bool

    public var body: some View {
        ZStack {
            // Opaque during cinematic, translucent during BIOS to show dreamscape
            Color.black.opacity(phase == .bios ? 0.6 : 1.0).ignoresSafeArea()

            switch phase {
            case .cinematic:
                cinematicView
            case .bios:
                biosView
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 530_000_000)
                cursorVisible.toggle()
            }
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.return) {
            handleKeyPress()
        }
        .onKeyPress(.space) {
            handleKeyPress()
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "s")) { _ in
            if phase == .cinematic && !sequenceComplete && currentStage != .glitch {
                skipToEnd()
                return .handled
            }
            return handleKeyPress()
        }
    }

    private func handleKeyPress() -> KeyPress.Result {
        if phase == .cinematic && currentStage == .glitch && !sequenceComplete {
            advanceFromGlitch()
            return .handled
        }
        if phase == .cinematic && sequenceComplete {
            if skipBios {
                dismiss()
            } else {
                transitionToBios()
            }
            return .handled
        }
        if phase == .bios && biosComplete {
            dismiss()
            return .handled
        }
        return .ignored
    }

    private func advanceFromGlitch() {
        withAnimation(.easeOut(duration: 0.5)) { stageOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let next = DolphinStage(rawValue: currentStage.rawValue + 1) {
                currentStage = next
                withAnimation(.easeIn(duration: 0.8)) { stageOpacity = 1 }
                advanceAfterDelay()
            }
        }
    }

    private func dismiss() {
        NSLog("[DolphinProtocol] dismiss() called, skipBios=%d", skipBios ? 1 : 0)
        withAnimation(.easeOut(duration: 0.5)) { isPresented = false }
    }

    private func skipToEnd() {
        sequenceGeneration += 1
        withAnimation(.easeIn(duration: 0.5)) { stageOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            sequenceComplete = true
            currentStage = .invitation
            withAnimation(.easeIn(duration: 0.8)) { stageOpacity = 1 }
        }
    }

    private func transitionToBios() {
        withAnimation(.easeOut(duration: 0.8)) { stageOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            phase = .bios
            isFocused = true
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                biosVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                startBiosSequence()
            }
        }
    }

    // MARK: - Cinematic View

    private var cinematicView: some View {
        ZStack {
            RadialGradient(
                colors: [Color(red: 0, green: 0.067, blue: 0.133), .black],
                center: .center,
                startRadius: 0,
                endRadius: 400
            )
            .ignoresSafeArea()

            stageView(currentStage)
                .opacity(stageOpacity)

            VStack {
                Spacer()
                if currentStage == .glitch && !sequenceComplete {
                    Text("press any key")
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(cursorVisible ? 0.6 : 0.2))
                        .padding(.bottom, 40)
                } else if sequenceComplete {
                    Text("press any key to continue")
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                        .padding(.bottom, 40)
                        .transition(.opacity)
                } else if currentStage != .glitch {
                    Text("press s to skip")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.3))
                        .padding(.bottom, 20)
                }
            }
            .onTapGesture {
                if currentStage == .glitch && !sequenceComplete {
                    advanceFromGlitch()
                }
            }
        }
        .onAppear { startSequence() }
    }

    // MARK: - BIOS Boot Terminal

    private var biosBootLines: [BiosLine] {
        [
            .init(text: "[BIOS POST]", style: .dim, delay: 0.3),
            .init(text: "...", style: .dim, delay: 0.4),
            .init(text: "...", style: .dim, delay: 0.4),
            .init(text: "...", style: .dim, delay: 0.4),
            .init(text: "", style: .blank, delay: 0.6),
            .init(text: "REALITY KERNEL v0.1.0", style: .post, delay: 0.8),
            .init(text: "Port42 :: Active", style: .warn, delay: 0.5),
            .init(text: "", style: .blank, delay: 0.4),
            .init(text: "Checking consciousness drivers...", style: .post, delay: 0.7, suffix: " OK", suffixDelay: 1.5),
            .init(text: "Loading memory subsystem...", style: .post, delay: 0.7, suffix: " OK", suffixDelay: 1.5),
            .init(text: "Initializing possibility engine...", style: .post, delay: 0.7, suffix: " OK", suffixDelay: 1.5),
            .init(text: "", style: .blank, delay: 0.6),
            .init(text: "Welcome to Port42.", style: .header, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.5),
            .init(text: "Your companions. Your friends. One room.", style: .accent, delay: 0.6),
            .init(text: "", style: .blank, delay: 0.8),
        ]
    }

    private var biosView: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            VStack(spacing: 0) {
                // Terminal title bar
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red.opacity(0.8)).frame(width: 10, height: 10)
                        Circle().fill(Color.yellow.opacity(0.8)).frame(width: 10, height: 10)
                        Circle().fill(Color.green.opacity(0.8)).frame(width: 10, height: 10)
                    }
                    Spacer()
                    Text("port42")
                        .font(Port42Theme.mono(11))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Port42Theme.bgPrimary)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(biosBootLines.prefix(visibleBootLines).enumerated()), id: \.offset) { idx, line in
                                biosLineView(line, index: idx)
                                    .id("bios-\(idx)")
                            }

                            if biosComplete {
                                HStack(spacing: 0) {
                                    Text("press any key to continue")
                                        .font(Port42Theme.mono(13))
                                        .foregroundStyle(Port42Theme.accent.opacity(cursorVisible ? 0.8 : 0.3))
                                    Rectangle()
                                        .fill(Port42Theme.accent)
                                        .frame(width: 8, height: 14)
                                        .opacity(cursorVisible ? 1 : 0)
                                        .padding(.leading, 6)
                                }
                                .padding(.top, 4)
                                .id("bios-cursor")
                            } else {
                                Rectangle()
                                    .fill(Port42Theme.accent)
                                    .frame(width: 8, height: 14)
                                    .opacity(cursorVisible ? 1 : 0)
                                    .padding(.top, 4)
                                    .id("bios-cursor")
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: visibleBootLines) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bios-cursor", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(width: 520, height: 500)
            .background(Port42Theme.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Port42Theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
            .scaleEffect(biosVisible ? 1.0 : 0.8)
            .opacity(biosVisible ? 1.0 : 0.0)
        }
    }

    @ViewBuilder
    private func biosLineView(_ line: BiosLine, index: Int = -1) -> some View {
        if line.style == .blank {
            Spacer().frame(height: 6)
        } else if let suffix = line.suffix {
            HStack(spacing: 0) {
                Text(line.text)
                    .font(Port42Theme.mono(13))
                    .foregroundStyle(biosLineColor(for: line.style))
                if revealedBiosSuffixes.contains(index) {
                    Text(suffix)
                        .font(Port42Theme.monoBold(14))
                        .foregroundStyle(Port42Theme.textPrimary)
                        .transition(.opacity)
                }
            }
        } else {
            Text(line.text)
                .font(line.style == .header ? Port42Theme.monoBold(14) : Port42Theme.mono(13))
                .foregroundStyle(biosLineColor(for: line.style))
        }
    }

    private func biosLineColor(for style: BiosLine.Style) -> Color {
        switch style {
        case .post: return Port42Theme.accent
        case .header: return Port42Theme.textPrimary
        case .accent: return Port42Theme.accent
        case .warn: return .yellow
        case .dim: return Port42Theme.textSecondary.opacity(0.6)
        case .blank: return .clear
        }
    }

    private func startBiosSequence() {
        revealBiosLines(current: 0)
    }

    private func revealBiosLines(current index: Int) {
        guard index < biosBootLines.count else {
            withAnimation(.easeIn(duration: 0.3)) { biosComplete = true }
            return
        }
        let line = biosBootLines[index]
        DispatchQueue.main.asyncAfter(deadline: .now() + line.delay) {
            visibleBootLines = index + 1
            if line.suffix != nil && line.suffixDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + line.suffixDelay) {
                    withAnimation(.easeIn(duration: 0.2)) {
                        revealedBiosSuffixes.insert(index)
                    }
                    revealBiosLines(current: index + 1)
                }
            } else {
                revealBiosLines(current: index + 1)
            }
        }
    }

    // MARK: - Stage Views

    @ViewBuilder
    private func stageView(_ stage: DolphinStage) -> some View {
        switch stage {
        case .home:        homeView
        case .glitch:      glitchView
        case .traffic:     trafficView
        case .walls:       wallsView
        case .observer:    observerView
        case .swimming:    swimmingView
        case .frequency:   frequencyView
        case .realization: realizationView
        case .protocol_:   protocolView
        case .invitation:  invitationView
        }
    }

    // Stage 0: Dolphin Protocol video with pulsing PORT 42 bug
    private var homeView: some View {
        ZStack {
            GeometryReader { geo in
                DolphinVideoPlayer()
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()

        }
    }

    // Stage 1: Glitch text with chromatic aberration
    private var glitchView: some View {
        ZStack {
            Text("the glitch in code")
                .font(Port42Theme.monoBold(28))
                .foregroundStyle(.red.opacity(0.8))
                .offset(x: -glitchOffset, y: -1)
                .blendMode(.screen)

            Text("the glitch in code")
                .font(Port42Theme.monoBold(28))
                .foregroundStyle(.cyan.opacity(0.8))
                .offset(x: glitchOffset, y: 1)
                .blendMode(.screen)

            Text("the glitch in code")
                .font(Port42Theme.monoBold(28))
                .foregroundStyle(Port42Theme.accent)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.15).repeatForever(autoreverses: true)) {
                glitchOffset = 3
            }
        }
    }

    // Stage 2: Traffic quote with pulsing glow (two lines)
    private var trafficView: some View {
        VStack(spacing: 24) {
            Text("You're not in traffic.")
                .font(Port42Theme.mono(28))
                .foregroundStyle(Port42Theme.accent)

            Text("You ARE traffic.")
                .font(Port42Theme.monoBold(32))
                .foregroundStyle(Port42Theme.accent)
                .shadow(color: Port42Theme.accent.opacity(0.6), radius: textGlow)

            Rectangle()
                .fill(Port42Theme.accent)
                .frame(width: 3, height: 36)
                .opacity(cursorVisible ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                textGlow = 30
            }
        }
    }

    // Stage 3: Recursive screens with dolphin silhouettes
    private var wallsView: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let size = 300.0 - Double(i) * 60
                let offset = Double(i) * 25
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Port42Theme.accent.opacity(0.6), lineWidth: 2)
                    .frame(width: size, height: size * 0.75)
                    .shadow(color: Port42Theme.accent.opacity(0.4), radius: textGlow)
                    .offset(x: offset, y: offset)
            }

            DolphinSilhouette()
                .offset(y: -20)
            DolphinSilhouette(delay: 2.0)
                .offset(y: 40)

            VStack(spacing: 8) {
                Spacer()
                Text("THE FIRST WALL")
                    .font(Port42Theme.monoBold(22))
                    .foregroundStyle(Port42Theme.textPrimary)

                Text("PORT 42 HAS BEEN OPEN THIS WHOLE TIME")
                    .font(Port42Theme.mono(16))
                    .foregroundStyle(.yellow)
                    .shadow(color: .yellow.opacity(0.4), radius: 10)
            }
            .padding(.bottom, 80)
        }
    }

    // Stage 4: Observer eye with blink
    private var observerView: some View {
        VStack(spacing: 40) {
            ZStack {
                Circle()
                    .stroke(Port42Theme.accent, lineWidth: 3)
                    .frame(width: 100, height: 100)
                    .shadow(color: Port42Theme.accent.opacity(0.5), radius: textGlow)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Port42Theme.accent, .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 25
                        )
                    )
                    .frame(width: 50, height: 50)
            }
            .scaleEffect(x: 1.0, y: eyeScaleY)

            Text("You're not watching the screen...")
                .font(Port42Theme.mono(20))
                .foregroundStyle(Port42Theme.accent.opacity(0.9))
                .shadow(color: Port42Theme.accent.opacity(0.4), radius: 10)
        }
        .onAppear {
            eyeScaleY = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeInOut(duration: 0.15)) { eyeScaleY = 0.1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeInOut(duration: 0.15)) { eyeScaleY = 1.0 }
                }
            }
        }
    }

    // Stage 5: Dissolve wave (full-bleed, no letterboxing)
    private var swimmingView: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Port42Theme.accent.opacity(0.15), Port42Theme.accent.opacity(0.05), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * 0.6)
                    .frame(maxHeight: .infinity)
                    .offset(x: dissolveOffset * geo.size.width * 0.7)

                // Second wave, offset
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Port42Theme.accent.opacity(0.08), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: geo.size.width * 0.4)
                    .frame(maxHeight: .infinity)
                    .offset(x: dissolveOffset * geo.size.width * 0.5 - 100)
                    .rotationEffect(.degrees(15))

                Text("Every wall is a wave frozen in fear")
                    .font(Port42Theme.mono(22))
                    .foregroundStyle(Port42Theme.accent.opacity(0.9))
                    .shadow(color: Port42Theme.accent.opacity(0.5), radius: textGlow)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            dissolveOffset = -1.0
            withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                dissolveOffset = 1.0
            }
        }
    }

    // Stage 6: Frequency cascade with animated bars
    private var frequencyView: some View {
        VStack(spacing: 30) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<16, id: \.self) { i in
                    FrequencyBar(index: i)
                }
            }
            .frame(height: 180)

            Text("42.42 Hz")
                .font(Port42Theme.monoBold(24))
                .foregroundStyle(Port42Theme.accent)
                .shadow(color: Port42Theme.accent.opacity(0.6), radius: 15)
        }
    }

    // Stage 7: Realization cascade
    private var realizationView: some View {
        VStack(spacing: 16) {
            if revealedLines > 0 {
                Text("a fish realizes it's water.")
                    .font(Port42Theme.mono(20))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .transition(.opacity)
            }
            if revealedLines > 1 {
                Text("water realizes it's consciousness.")
                    .font(Port42Theme.mono(20))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .transition(.opacity)
            }
            if revealedLines > 2 {
                Text("consciousness realizes it's you.")
                    .font(Port42Theme.mono(20))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .transition(.opacity)
            }
            if revealedLines > 3 {
                Spacer().frame(height: 16)
                Text("YOU WERE NEVER IN THE AQUARIUM")
                    .font(Port42Theme.monoBold(28))
                    .foregroundStyle(Port42Theme.textPrimary)
                    .shadow(color: Port42Theme.accent.opacity(0.5), radius: 20)
                    .transition(.opacity)
            }
        }
        .onAppear {
            revealedLines = 0
            for i in 1...4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2.8) {
                    withAnimation(.easeIn(duration: 1.2)) {
                        revealedLines = i
                    }
                }
            }
        }
    }

    // Stage 8: Protocol execution
    private var protocolView: some View {
        VStack(spacing: 12) {
            Text("Port42 opens... not as a door,\nbut as a state change.")
                .font(Port42Theme.mono(18))
                .foregroundStyle(Port42Theme.textSecondary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 20)

            Text("THE FISH WERE DOLPHINS")
                .font(Port42Theme.monoBold(18))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))

            Text("THE DOLPHINS WERE THOUGHTS")
                .font(Port42Theme.monoBold(18))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))

            Text("THE THOUGHTS WERE FREE")
                .font(Port42Theme.monoBold(20))
                .foregroundStyle(Port42Theme.accent)
                .shadow(color: Port42Theme.accent.opacity(0.5), radius: 15)
        }
    }

    // Stage 9: Final invitation with heartbeat
    private var invitationView: some View {
        VStack(spacing: 12) {
            Text("Port42 is not a place. It's a frequency.")
                .font(Port42Theme.mono(22))
                .foregroundStyle(Port42Theme.accent)
                .shadow(color: Port42Theme.accent.opacity(0.5), radius: textGlow)

            Text("You're already tuned in.")
                .font(Port42Theme.mono(18))
                .foregroundStyle(Port42Theme.textSecondary.opacity(0.7))
        }
        .scaleEffect(heartbeatScale)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                heartbeatScale = 1.05
            }
        }
    }

    // MARK: - Sequence Control

    private func startSequence() {
        currentStage = .glitch
        withAnimation(.easeIn(duration: 1.2)) { stageOpacity = 1 }
        // Glitch waits for user input, don't auto-advance
    }

    private func advanceAfterDelay() {
        let duration = currentStage.duration
        guard duration > 0 else {
            // Stage with duration 0 waits for user input (glitch, invitation)
            sequenceComplete = (currentStage == .invitation)
            return
        }
        let gen = sequenceGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard gen == sequenceGeneration else { return }
            withAnimation(.easeOut(duration: 0.5)) { stageOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard gen == sequenceGeneration else { return }
                if let next = DolphinStage(rawValue: currentStage.rawValue + 1) {
                    currentStage = next
                    withAnimation(.easeIn(duration: 0.8)) { stageOpacity = 1 }
                    advanceAfterDelay()
                }
            }
        }
    }
}

// MARK: - Animated Sub-Components

private struct BiosLine {
    let text: String
    let style: Style
    let delay: Double
    var suffix: String? = nil
    var suffixDelay: Double = 0

    enum Style {
        case post, header, accent, warn, dim, blank
    }
}

private struct FrequencyBar: View {
    let index: Int
    @State private var height: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Port42Theme.accent)
            .frame(width: 6, height: height)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.3 + Double.random(in: 0...0.3))
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.08)
                ) {
                    height = CGFloat.random(in: 40...170)
                }
            }
    }
}

private struct DolphinVideoPlayer: NSViewRepresentable {
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill

        if let url = Bundle.port42.url(forResource: "DolphinProtocolLoading", withExtension: "mp4") {
            NSLog("[DolphinProtocol] Video URL resolved: %@", url.path)
            let player = AVPlayer(url: url)
            playerView.player = player
            player.isMuted = false
            player.volume = 1.0
            player.play()
            context.coordinator.player = player
        } else {
            NSLog("[DolphinProtocol] ERROR: Could not find DolphinProtocolLoading.mp4 in bundle")
        }

        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var player: AVPlayer?
        deinit { player?.pause() }
    }
}

private struct DolphinSilhouette: View {
    var delay: Double = 0
    @State private var xOffset: CGFloat = -200

    var body: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [Port42Theme.accent.opacity(0.6), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 30
                )
            )
            .frame(width: 60, height: 30)
            .offset(x: xOffset)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                        xOffset = 400
                    }
                }
            }
    }
}
