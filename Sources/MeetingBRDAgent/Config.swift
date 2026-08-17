import Foundation

/// Loads settings from ~/.meeting-brd-agent/config.json so API keys never live in the repo.
struct Config: Codable {
    var obsHost: String
    var obsPort: Int
    var obsPassword: String
    var deepgramKey: String
    var anthropicKey: String
    var outputFolder: String

    enum CodingKeys: String, CodingKey {
        case obsHost, obsPort, obsPassword, deepgramKey, anthropicKey, outputFolder
    }

    init(obsHost: String, obsPort: Int, obsPassword: String, deepgramKey: String, anthropicKey: String, outputFolder: String) {
        self.obsHost = obsHost
        self.obsPort = obsPort
        self.obsPassword = obsPassword
        self.deepgramKey = deepgramKey
        self.anthropicKey = anthropicKey
        self.outputFolder = outputFolder
    }

    /// Tolerant of missing/renamed keys so a schema change never wipes an already-configured file —
    /// falls back to "CHANGE_ME" per-field instead of discarding the whole config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        obsHost = (try? c.decode(String.self, forKey: .obsHost)) ?? "127.0.0.1"
        obsPort = (try? c.decode(Int.self, forKey: .obsPort)) ?? 4455
        obsPassword = (try? c.decode(String.self, forKey: .obsPassword)) ?? "CHANGE_ME"
        anthropicKey = (try? c.decode(String.self, forKey: .anthropicKey)) ?? "CHANGE_ME"
        outputFolder = (try? c.decode(String.self, forKey: .outputFolder)) ?? "CHANGE_ME"
        // Note: a pre-migration file's "assemblyAIKey" is intentionally not reused here —
        // an AssemblyAI key isn't a valid Deepgram key, so it must be re-entered either way.
        deepgramKey = (try? c.decode(String.self, forKey: .deepgramKey)) ?? "CHANGE_ME"
    }

    static let path: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-brd-agent", isDirectory: true)
        return dir.appendingPathComponent("config.json")
    }()

    static func loadOrCreateDefault() -> Config {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if let data = try? Data(contentsOf: path),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }

        let home = fm.homeDirectoryForCurrentUser.path
        let defaultConfig = Config(
            obsHost: "127.0.0.1",
            obsPort: 4455,
            obsPassword: "CHANGE_ME",
            deepgramKey: "CHANGE_ME",
            anthropicKey: "CHANGE_ME",
            outputFolder: "\(home)/Documents/MeetingDocs"
        )
        if let data = try? JSONEncoder().encode(defaultConfig) {
            let pretty = try? JSONSerialization.jsonObject(with: data)
            if let pretty, let prettyData = try? JSONSerialization.data(withJSONObject: pretty, options: .prettyPrinted) {
                try? prettyData.write(to: path)
            } else {
                try? data.write(to: path)
            }
        }
        return defaultConfig
    }
}
