import Testing
import Foundation
@testable import Port42Lib

// Quitting setup after typing a name used to land the next launch in an empty shell with a nameless
// placeholder space: the person is saved at the name, and "setup complete" meant only "a person
// exists" (GM, 2026-09-26). Setup is finished when it has made what it ends by making.
@Suite("Setup resumes when quit halfway")
@MainActor
struct SetupResumeTests {

    @Test("finished means a person and a space or companion")
    func rule() {
        #expect(!AppState.setupFinished(hasUser: false, spaces: 3, companions: 1))
        #expect(!AppState.setupFinished(hasUser: true, spaces: 0, companions: 0), "a name typed, then quit")
        #expect(AppState.setupFinished(hasUser: true, spaces: 1, companions: 0))
        #expect(AppState.setupFinished(hasUser: true, spaces: 0, companions: 1))
    }

    @Test("a launch after a setup quit at the name goes back to setup; a finished install does not")
    func launch() throws {
        let halfway = try DatabaseService(inMemory: true)
        try halfway.saveUser(AppUser.createForTesting(displayName: "gordon"))
        #expect(AppState(db: halfway).isSetupComplete == false, "an empty shell instead of setup")

        let done = try DatabaseService(inMemory: true)
        try done.saveUser(AppUser.createForTesting(displayName: "gordon"))
        try done.saveSpace(Space.create(name: "genesis"))
        #expect(AppState(db: done).isSetupComplete == true)
    }
}
