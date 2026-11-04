import Foundation

/// The names a new project gets from the name the user typed: id and folder names, and the Xcode project name.
struct ProjectNames: Equatable {
    let slug: String
    let repoDir: String
    let dataDir: String
    let xcodeName: String
}

/// Pure naming rules for "Add project". The slug is the project id, the repo folder, the git repository name and the data folder name.
enum ProjectNaming {
    /// Lowercase letters, digits and single dashes; starts with a letter; 2 to 40 characters. Nil when the name has no usable slug.
    static func slug(from name: String) -> String? {
        let folded = fold(name).lowercased()
        var out = ""
        var lastDash = true   // swallows leading separators
        for ch in folded {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 40 { out = String(out.prefix(40)); while out.hasSuffix("-") { out.removeLast() } }
        guard out.count >= 2, let first = out.first, first.isLetter else { return nil }
        return out
    }

    /// "Pet Diary" → "PetDiary"; a name that starts with a digit gets an "App" prefix. Never empty.
    static func xcodeName(from name: String) -> String {
        let words = fold(name).split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let joined = String(words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined().prefix(56))
        if joined.isEmpty { return "App" }
        return joined.first!.isNumber ? "App" + joined : joined
    }

    static func names(for name: String, repoParent: String, dataRoot: String) -> ProjectNames? {
        guard let slug = slug(from: name) else { return nil }
        return ProjectNames(slug: slug, repoDir: join(repoParent, slug), dataDir: join(dataRoot, slug), xcodeName: xcodeName(from: name))
    }

    /// What already exists and would be overwritten; empty means creating is safe.
    static func collisions(of names: ProjectNames, existingIDs: Set<String>, fileExists: (String) -> Bool) -> [String] {
        var found: [String] = []
        if existingIDs.contains(names.slug) { found.append("A project with the id \"\(names.slug)\" is already in the list.") }
        if fileExists(names.repoDir) { found.append("\(names.repoDir) already exists.") }
        if fileExists(names.dataDir) { found.append("\(names.dataDir) already exists.") }
        return found
    }

    /// Turkish letters first (the generic transform leaves dotless ı alone), then the accents of the other languages.
    private static func fold(_ s: String) -> String {
        let turkish = s.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "I")
        return turkish.applyingTransform(.stripDiacritics, reverse: false) ?? turkish
    }

    private static func join(_ base: String, _ name: String) -> String { base.hasSuffix("/") ? base + name : base + "/" + name }
}
