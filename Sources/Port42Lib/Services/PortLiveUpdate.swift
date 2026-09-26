import Foundation

/// How a write to a port's HTML reaches the running page (GM, 2026-09-26: not every write needs a
/// reload). A reload replaces the document and loses everything the page was holding: a paused
/// animation, a drawn canvas, a half-filled form. So `updatePort` reloads only when nothing less
/// will do:
///
/// - **unchanged**: the new HTML is the old HTML. Nothing is shown, stored or versioned.
/// - **styles**: only the contents of `<style>` blocks differ. The page's own style elements are
///   rewritten in place; its scripts, DOM and state are untouched.
/// - **offer**: anything else. The page gets a cancelable `port42:update` event carrying the new
///   HTML in `detail.html`. A page that can apply the change itself (a shader recompiling its
///   program, say) calls `preventDefault()` and keeps its state; otherwise the port reloads.
///
/// Every live path answers whether it applied, and a false answer reloads, so a page whose style
/// elements no longer match what was planned (a script added or removed one) is never half-updated.
public enum PortLiveUpdate {

    public enum Plan: Equatable {
        case unchanged
        case styles([String])
        case offer
    }

    /// What a write did, reported back to the caller that made it.
    public enum Outcome: String {
        case unchanged
        case styles          // applied in place
        case handledByPage   // the page took the `port42:update` event
        case reloaded
    }

    public static func plan(old: String, new: String) -> Plan {
        if old == new { return .unchanged }
        let a = styleBlocks(old), b = styleBlocks(new)
        if a.skeleton == b.skeleton, a.css.count == b.css.count { return .styles(b.css) }
        return .offer
    }

    /// The HTML with every `<style>` block's contents removed, and those contents in order.
    static func styleBlocks(_ html: String) -> (skeleton: String, css: [String]) {
        guard let re = try? NSRegularExpression(pattern: "(<style\\b[^>]*>)(.*?)(</style\\s*>)",
                                                options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return (html, []) }
        let ns = html as NSString
        var css: [String] = []
        var skeleton = ""
        var last = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            skeleton += ns.substring(with: NSRange(location: last, length: m.range(at: 2).location - last))
            css.append(ns.substring(with: m.range(at: 2)))
            last = m.range(at: 2).location + m.range(at: 2).length
        }
        skeleton += ns.substring(from: last)
        return (skeleton, css)
    }

    /// Rewrites the page's own style elements (the wrapper's are marked `data-port42`). Refuses, so
    /// the caller reloads, when their number no longer matches the document's.
    static let stylesJS = """
        const els = [...document.querySelectorAll('style:not([data-port42])')];
        if (els.length !== css.length) return false;
        els.forEach((el, i) => { if (el.textContent !== css[i]) el.textContent = css[i]; });
        return true;
        """

    /// Offers the new HTML to the page; true when a listener called preventDefault().
    static let offerJS = """
        const e = new CustomEvent('port42:update', { detail: { html }, cancelable: true });
        window.dispatchEvent(e);
        return e.defaultPrevented;
        """
}
