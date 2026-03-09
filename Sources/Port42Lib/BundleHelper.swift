import Foundation

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

        Swift.fatalError("Could not find resource bundle \(bundleName)")
    }()
}
