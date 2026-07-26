import Testing
import Foundation
@testable import Port42Lib

/// Onboarding-into-the-shell (docs/plan-unify-onboarding-shell.md) — the phase 1 + 2 gate.
///
/// The first swim runs inside the real shell: setup ends by flipping into `ShellView` with the
/// space's chat tile focused, instead of `SetupView`'s bespoke `.swim` surface. Only the pure
/// decision logic at each seam is testable here; the views, the dive/breakout videos and the
/// zoom animation are verified manually in a fresh Dev3.
@Suite("Onboarding into the shell")
struct OnboardingShellTests {

    // MARK: - Phase 1: first boot plays the cinematic, then the BIOS

    @MainActor
    @Test("First boot skips the lock screen — no identity, no dreamscape loop")
    func firstBootShowsBios() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        #expect(state.currentUser == nil)
        #expect(state.isSetupComplete == false)
        #expect(state.showDreamscape == false)
        // …which is the setup terminal once the cinematic is done, not the lock screen.
        #expect(RootScreen.decide(showDreamscape: state.showDreamscape,
                                  isSetupComplete: state.isSetupComplete,
                                  transitionPlaying: false, bootCinematicDone: true) == .setup)
    }

    @MainActor
    @Test("First boot plays the pre-boot cinematic — the root drives it, not the lock screen")
    func firstBootPlaysCinematic() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        #expect(RootScreen.playsBootCinematicAtLaunch(hasIdentity: state.currentUser != nil,
                                                      isSetupComplete: state.isSetupComplete))
        // …and while it plays, the root MUST be `.none`. If `bootCinematicDone` were true here
        // the setup terminal would render under the video and the fix would look applied
        // without being applied — the regression this test exists to catch.
        #expect(RootScreen.decide(showDreamscape: state.showDreamscape,
                                  isSetupComplete: state.isSetupComplete,
                                  transitionPlaying: false, bootCinematicDone: false) == .none)
    }

    @Test("A launch with an identity never plays the cinematic")
    func returningLaunchSkipsCinematic() {
        // Returning user: straight to the lock screen / shell.
        #expect(RootScreen.playsBootCinematicAtLaunch(hasIdentity: true, isSetupComplete: true) == false)
        // Power off keeps the data but drops setup: still an identity on disk, still no cinematic.
        #expect(RootScreen.playsBootCinematicAtLaunch(hasIdentity: true, isSetupComplete: false) == false)
    }

    // MARK: - Phase 1: the root screen truth table

    @Test("Locked wins over everything")
    func lockScreenWins() {
        #expect(RootScreen.decide(showDreamscape: true, isSetupComplete: true,
                                  transitionPlaying: false, bootCinematicDone: true) == .lock)
        #expect(RootScreen.decide(showDreamscape: true, isSetupComplete: false,
                                  transitionPlaying: true, bootCinematicDone: false) == .lock)
    }

    @Test("Fresh install shows setup once the boot cinematic is done")
    func freshInstallShowsSetup() {
        #expect(RootScreen.decide(showDreamscape: false, isSetupComplete: false,
                                  transitionPlaying: false, bootCinematicDone: true) == .setup)
        // Before the cinematic finishes there is no root screen — the overlay covers the gap.
        #expect(RootScreen.decide(showDreamscape: false, isSetupComplete: false,
                                  transitionPlaying: false, bootCinematicDone: false) == .none)
    }

    @Test("Setup complete lands on the shell — the first-run seam")
    func setupCompleteShowsShell() {
        #expect(RootScreen.decide(showDreamscape: false, isSetupComplete: true,
                                  transitionPlaying: false, bootCinematicDone: true) == .shell)
        // Returning user, cinematic never ran: still the shell.
        #expect(RootScreen.decide(showDreamscape: false, isSetupComplete: true,
                                  transitionPlaying: false, bootCinematicDone: false) == .shell)
    }

    @Test("Mid-transition mounts the shell UNDER the video overlay (no blank frame)")
    func midTransitionMountsShell() {
        #expect(RootScreen.decide(showDreamscape: false, isSetupComplete: false,
                                  transitionPlaying: true, bootCinematicDone: false) == .shell)
    }

    // MARK: - Phase 2: where the shell lands

    @Test("Onboarding lands FOCUSED on the chat tile")
    func onboardingFocusesChat() {
        #expect(ShellState.initialZoom(hasCurrentSpace: true, allRested: false,
                                       onboarding: true, chatUdid: "chat-1") == .focus("chat-1"))
        // A fresh direct space is not in the working set yet — onboarding must still not
        // strand the user in the galaxy.
        #expect(ShellState.initialZoom(hasCurrentSpace: true, allRested: true,
                                       onboarding: true, chatUdid: "chat-1") == .focus("chat-1"))
    }

    @Test("Onboarding with no chat tile yet holds at the desktop, never the galaxy")
    func onboardingWithoutChatHoldsAtSpace() {
        #expect(ShellState.initialZoom(hasCurrentSpace: true, allRested: true,
                                       onboarding: true, chatUdid: nil) == .space)
        #expect(ShellState.initialZoom(hasCurrentSpace: false, allRested: true,
                                       onboarding: true, chatUdid: nil) == .space)
    }

    @Test("A returning user is never force-focused")
    func returningUserUnchanged() {
        #expect(ShellState.initialZoom(hasCurrentSpace: true, allRested: false,
                                       onboarding: false, chatUdid: "chat-1") == .space)
        #expect(ShellState.initialZoom(hasCurrentSpace: true, allRested: true,
                                       onboarding: false, chatUdid: "chat-1") == .galaxy)
        // The existing two-argument call site keeps its behavior.
        #expect(ShellState.initialZoom(hasCurrentSpace: true, allRested: false) == .space)
        #expect(ShellState.initialZoom(hasCurrentSpace: false, allRested: true) == .galaxy)
    }

    // MARK: - Phase 3: seeding the first message

    @MainActor
    @Test("The first message seeds once, and only into an empty chat")
    func firstMessageSeedsOnce() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)

        // Not onboarding → no seed.
        state.seedOnboardingFirstMessage()
        #expect(state.isOnboarding == false)

        state.enterShellFromSetup()
        #expect(state.isOnboarding)
        #expect(state.isSetupComplete)

        // A non-empty chat is never seeded over (the guard moved from SetupView).
        state.messages = [Message.create(spaceId: "s", senderId: "u", senderName: "u", content: "hi")]
        state.seedOnboardingFirstMessage()

        state.endOnboarding()
        #expect(state.isOnboarding == false)
    }

    @MainActor
    @Test("The opening line is PREFILLED as a draft, never sent for the user")
    func firstMessageIsADraft() async throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let space = Space.create(name: "genesis")
        try db.saveSpace(space)
        state.spaces = try db.getRegularSpaces()
        state.currentSpace = space
        state.enterShellFromSetup()

        state.seedOnboardingFirstMessage()
        try await Task.sleep(nanoseconds: 900_000_000)   // the seed defers ~0.5s

        // It waits in the input for the user to press Enter — nothing was sent.
        #expect(state.chatDrafts[space.id]?.contains("what is this place?") == true)
        #expect(state.messages.isEmpty)
    }

    // MARK: - Phases 4/6: first run ends at the first zoom-out, and the breakout plays there

    @MainActor
    @Test("The breakout starts on the focused port's frame, not full screen")
    func breakoutStartsOnThePort() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let shell = ShellState(appState: state)
        let area = CGSize(width: 1600, height: 1000)

        shell.startBreakout(area: area)
        let from = try #require(shell.breakoutFrom)
        #expect(from == ShellPlacement.focusRect(in: area), "it must start where the port was")
        #expect(from.width < area.width, "starting full-bleed would lose the grow-out")

        // Idempotent: a second zoom-out mid-play cannot restart it.
        shell.startBreakout(area: CGSize(width: 100, height: 100))
        #expect(shell.breakoutFrom == from)

        shell.endBreakout()
        #expect(shell.breakoutFrom == nil)
    }

    @MainActor
    @Test("Onboarding is a one-shot: ending it twice is harmless, and it never restarts")
    func onboardingEndsOnce() throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        state.enterShellFromSetup()
        #expect(state.isOnboarding)

        state.endOnboarding()
        state.endOnboarding()
        #expect(state.isOnboarding == false)

        // A returning user's zoom-out must not qualify: the flag is the whole guard.
        #expect(ShellState.initialZoom(hasCurrentSpace: true, allRested: false,
                                       onboarding: state.isOnboarding, chatUdid: "c") == .space)
    }

    @MainActor
    @Test("A draft the user is already typing is never clobbered")
    func prefillNeverClobbersTyping() async throws {
        let db = try DatabaseService(inMemory: true)
        let state = AppState(db: db)
        let space = Space.create(name: "genesis")
        try db.saveSpace(space)
        state.spaces = try db.getRegularSpaces()
        state.currentSpace = space
        state.enterShellFromSetup()
        state.chatDrafts[space.id] = "already typing this"

        state.seedOnboardingFirstMessage()
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(state.chatDrafts[space.id] == "already typing this")
    }
}
