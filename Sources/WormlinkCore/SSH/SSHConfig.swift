import Foundation

/// Leitura do `~/.ssh/config` com a mesma regra do OpenSSH: para cada opção vale o primeiro valor
/// encontrado nos blocos `Host` que casam com o nome digitado. Usado como o Cyberduck faz
/// (HostName, User, Port, IdentityFile, IdentityAgent, ProxyJump).
public struct SSHConfig: Sendable {
    public struct Resolved: Sendable, Equatable {
        public var hostName: String?
        public var user: String?
        public var port: Int?
        public var identityFiles: [String] = []
        public var identityAgent: String?
        public var proxyJump: String?
        public var identitiesOnly = false
    }

    struct Block {
        var patterns: [String]
        var options: [(String, String)]
    }

    let blocks: [Block]

    public init(text: String) {
        var blocks: [Block] = [Block(patterns: ["*"], options: [])]   // opções antes do primeiro Host valem para todos
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (key, value) = Self.split(line)
            switch key {
            case "host": blocks.append(Block(patterns: value.split(separator: " ").map(String.init), options: []))
            case "match": blocks.append(Block(patterns: [], options: []))   // Match não é suportado: bloco ignorado
            default: blocks[blocks.count - 1].options.append((key, value))
            }
        }
        self.blocks = blocks
    }

    /// Caminho do config (os testes trocam por um arquivo temporário).
    nonisolated(unsafe) public static var location = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config")

    public static func load(_ url: URL = location) -> SSHConfig {
        SSHConfig(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// "Key value", "Key=value" ou "Key = value"; valores entre aspas perdem as aspas.
    static func split(_ line: String) -> (String, String) {
        let separators = CharacterSet(charactersIn: " \t=")
        guard let range = line.rangeOfCharacter(from: separators) else { return (line.lowercased(), "") }
        let key = String(line[..<range.lowerBound]).lowercased()
        var value = String(line[range.lowerBound...]).trimmingCharacters(in: separators.union(.whitespaces))
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        return (key, value)
    }

    /// Curingas `*` e `?`, negação com `!`.
    static func matches(_ patterns: [String], _ host: String) -> Bool {
        var matched = false
        for pattern in patterns {
            let negated = pattern.hasPrefix("!")
            let p = negated ? String(pattern.dropFirst()) : pattern
            if fnmatch(p.lowercased(), host.lowercased(), 0) == 0 {
                if negated { return false }
                matched = true
            }
        }
        return matched
    }

    public func resolve(_ host: String) -> Resolved {
        var result = Resolved()
        var seen = Set<String>()
        for block in blocks where Self.matches(block.patterns, host) {
            for (key, value) in block.options {
                if key == "identityfile" {
                    result.identityFiles.append(Self.expand(value, host: host, user: result.user))
                    continue
                }
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                switch key {
                case "hostname": result.hostName = value.replacingOccurrences(of: "%h", with: host)
                case "user": result.user = value
                case "port": result.port = Int(value)
                case "identityagent": result.identityAgent = value.lowercased() == "none" ? "none" : Self.expand(value, host: host, user: nil)
                case "proxyjump": result.proxyJump = value.lowercased() == "none" ? nil : value
                case "identitiesonly": result.identitiesOnly = value.lowercased() == "yes"
                default: break
                }
            }
        }
        return result
    }

    static func expand(_ path: String, host: String, user: String?) -> String {
        var p = path.replacingOccurrences(of: "%d", with: FileManager.default.homeDirectoryForCurrentUser.path)
            .replacingOccurrences(of: "%h", with: host)
            .replacingOccurrences(of: "%u", with: NSUserName())
            .replacingOccurrences(of: "%r", with: user ?? NSUserName())
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        return p
    }
}
