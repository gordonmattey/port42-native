import Testing
@testable import Port42Lib

@Suite("Port Push Dispatch")
struct PortPushDispatchTests {

    @Test("a terminal id routes to the terminal path")
    func terminalRoutes() {
        #expect(PortPushRoute.classify(isTerminal: true, isWeb: false) == .terminal)
    }

    @Test("a web id routes to the web path")
    func webRoutes() {
        #expect(PortPushRoute.classify(isTerminal: false, isWeb: true) == .web)
    }

    @Test("terminal wins when an id somehow resolves to both")
    func terminalPrecedence() {
        #expect(PortPushRoute.classify(isTerminal: true, isWeb: true) == .terminal)
    }

    @Test("an unknown id is notFound")
    func unknownNotFound() {
        #expect(PortPushRoute.classify(isTerminal: false, isWeb: false) == .notFound)
    }
}
