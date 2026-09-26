import Testing
import Foundation
import JavaScriptCore
@testable import Port42Lib

// Scripts Port42 injects into a page live in Swift strings, where "\n" is a real newline: one written
// as '\n' inside a JS string split the string, the whole console script failed to parse, and no port
// captured any console output (caught by a test, 2026-09-26). Every injected script must compile.
@Suite("Injected scripts parse")
struct InjectedScriptSyntaxTests {
    /// Compiles without running (`new Function(src)`), so a script that needs `window` still passes.
    func syntaxError(_ src: String, asyncBody: Bool = false) -> String? {
        let ctx = JSContext()!
        var err: String?
        ctx.exceptionHandler = { _, e in err = e?.toString() }
        ctx.setObject(src, forKeyedSubscript: "__src" as NSString)
        ctx.evaluateScript(asyncBody ? "(async function(){}).constructor(__src)" : "new Function(__src)")
        return err
    }

    @Test("every script injected into a port page compiles")
    func allCompile() {
        let scripts: [(String, String, Bool)] = [
            ("consoleJS", PortWebViewFactory.consoleJS, false),
            ("viewportJS", PortWebViewFactory.viewportJS, false),
            ("heightJS", PortWebViewFactory.heightJS, false),
            ("bridgeJS", PortBridge.bridgeJS, false),
            ("stylesJS", PortLiveUpdate.stylesJS, true),
            ("offerJS", PortLiveUpdate.offerJS, true),
        ]
        for (name, src, isAsyncBody) in scripts {
            #expect(syntaxError(src, asyncBody: isAsyncBody) == nil, "\(name) does not parse: \(syntaxError(src, asyncBody: isAsyncBody) ?? "")")
        }
    }
}
