import Foundation

/// An absolute, normalised path that is compared by components, not by string
/// prefix, so `/Volumes/agent-1` never "contains" `/Volumes/agent-10`.
///
/// Two roots are supported: `/` and `~` (the user's home). They are kept apart
/// on purpose: `~/x` and `/Users/me/x` may be the same folder on disk, so write
/// every envelope in the same style if you want overlaps between them caught.
///
/// `contains`, `overlaps` and `isSame(as:)` ignore letter case, like the
/// default (case-insensitive) APFS volume. `==` is exact spelling.
public struct EnvelopePath: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// Path components after the root. The first component is `"~"` for
    /// home-relative paths.
    public let components: [String]

    /// Parses `"/abs/path"` or `"~/relative-to-home"`.
    ///
    /// Returns `nil` for an empty or relative path, for one whose `..`
    /// segments would climb above its root, and for `/~/...`, which would
    /// otherwise read as the home directory.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        var parts: [String]
        let rest: Substring
        if trimmed.hasPrefix("/") {
            parts = []
            rest = Substring(trimmed)
        } else if trimmed == "~" || trimmed.hasPrefix("~/") {
            parts = ["~"]
            rest = trimmed.dropFirst()
        } else {
            return nil
        }
        let rootDepth = parts.count
        for piece in rest.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".":
                continue
            case "..":
                guard parts.count > rootDepth else { return nil }
                parts.removeLast()
            default:
                parts.append(String(piece))
            }
        }
        if rootDepth == 0, parts.first == "~" { return nil }
        components = parts
    }

    private init(components: [String]) {
        self.components = components
    }

    /// `/`
    public static let root = EnvelopePath(components: [])
    /// `~`
    public static let home = EnvelopePath(components: ["~"])

    /// True when `other` is this path or lives somewhere below it.
    public func contains(_ other: EnvelopePath) -> Bool {
        other.folded.starts(with: folded)
    }

    /// The same location, ignoring letter case.
    public func isSame(as other: EnvelopePath) -> Bool {
        folded == other.folded
    }

    private var folded: [String] { components.map { $0.lowercased() } }

    /// True when either path contains the other: writing to one can change
    /// what is under the other.
    public func overlaps(_ other: EnvelopePath) -> Bool {
        contains(other) || other.contains(self)
    }

    /// This path with one more component. Slashes and `..` in `name` are
    /// rejected so a child can never escape its parent.
    public func appending(_ name: String) -> EnvelopePath? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        if components.isEmpty, name == "~" { return nil }
        return EnvelopePath(components: components + [name])
    }

    public var description: String {
        if components.first == "~" {
            let tail = components.dropFirst().joined(separator: "/")
            return tail.isEmpty ? "~" : "~/" + tail
        }
        return "/" + components.joined(separator: "/")
    }

    public static func < (lhs: EnvelopePath, rhs: EnvelopePath) -> Bool {
        lhs.description < rhs.description
    }
}
