import Foundation

/// Anchor class for locating the module's built products directory (SPM test / debug layouts).
private final class Port42BundleFinder {}

/// SPM's generated Bundle.module looks at Bundle.main.bundleURL (the .app root)
/// but macOS codesigning requires resources in Contents/Resources/.
extension Bundle {
    static let port42: Bundle = {
        let bundleName = "Port42_Port42Lib"

        // Contents/Resources/ (packaged app)
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }

        // SPM build layout (swift test / swift run): the resource bundle sits in the built-products
        // directory, next to the binary that links this module. Without this, tests fell back to
        // Bundle.main and every bundled resource (llms-preamble, ports-context) silently loaded as
        // its fallback string — so tests exercised different docs than the app serves.
        let buildDir = Bundle(for: Port42BundleFinder.self).bundleURL.deletingLastPathComponent()
        if let bundle = Bundle(url: buildDir.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }

        // Last resort: degrade gracefully (resources won't load, callers use fallback strings).
        return Bundle.main
    }()
}
