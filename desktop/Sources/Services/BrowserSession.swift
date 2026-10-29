import Foundation

enum BrowserSessionBrowser: String, Codable, CaseIterable, Identifiable {
    case zen, firefox, chrome, safari, edge, brave
    var id: String { rawValue }
    var label: String {
        switch self {
        case .zen: "Zen"
        case .firefox: "Firefox"
        case .chrome: "Chrome"
        case .safari: "Safari"
        case .edge: "Edge"
        case .brave: "Brave"
        }
    }
}

enum BrowserSession {
    static let environmentKey = "NEEDLE_COOKIES_FROM_BROWSER"

    static func sessionSettings(_ snapshot: NeedleSettings, current: NeedleSettings? = nil) -> NeedleSettings {
        let saved = current ?? UserDefaults.standard.data(forKey: "needle.settings")
            .flatMap { try? JSONDecoder().decode(NeedleSettings.self, from: $0) }
        guard let saved else { return snapshot }
        var result = snapshot
        result.browserSession = saved.browserSession
        result.browserProfile = saved.browserProfile
        return result
    }

    static func selector(settings: NeedleSettings, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String? {
        let settings = sessionSettings(settings)
        guard let browser = settings.browserSession else { return nil }
        let profile = settings.browserProfile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if browser == .zen {
            let root = home.appendingPathComponent("Library/Application Support/zen")
            let path = try profile.isEmpty ? zenDefaultProfile(root: root).path : (profile as NSString).expandingTildeInPath
            return "firefox:\(path)"
        }
        return browser.rawValue + (profile.isEmpty ? "" : ":\(profile)")
    }

    static func arguments(settings: NeedleSettings) throws -> [String] {
        try selector(settings: settings).map { ["--cookies-from-browser", $0] } ?? []
    }

    static func environment(settings: NeedleSettings, inherited: [String: String]) throws -> [String: String] {
        var result = inherited
        result[environmentKey] = try selector(settings: settings)
        return result
    }

    static func zenDefaultProfile(root: URL) throws -> URL {
        let message = "Choose a Zen default profile in Zen, or enter its full profile folder path in Needle’s Browser sign-in settings."
        guard let text = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) else {
            throw CLIError.message(message)
        }
        var sections: [(String, [String: String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if !line.hasPrefix(";"), !line.hasPrefix("#"), let equals = line.firstIndex(of: "="), !sections.isEmpty {
                let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].1[key] = value
            }
        }
        let installDefaults = Set(sections.filter { $0.0.hasPrefix("Install") }.compactMap { $0.1["Default"] }.filter { !$0.isEmpty })
        let profileDefaults = sections.filter { $0.0.hasPrefix("Profile") && $0.1["Default"] == "1" }
        let path: String
        let relative: Bool
        if installDefaults.count == 1, let installed = installDefaults.first {
            path = installed
            relative = !installed.hasPrefix("/")
        } else if installDefaults.isEmpty, profileDefaults.count == 1, let selected = profileDefaults.first, let selectedPath = selected.1["Path"] {
            path = selectedPath
            relative = selected.1["IsRelative"] != "0"
        } else {
            throw CLIError.message(message)
        }
        guard !path.isEmpty else { throw CLIError.message(message) }
        let url = relative ? root.appendingPathComponent(path) : URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError.message("The selected Zen profile folder is missing. \(message)")
        }
        return url.standardizedFileURL
    }
}
