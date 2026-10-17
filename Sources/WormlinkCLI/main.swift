import Foundation
import WormlinkCore

/// `wormlink`: linha de comando do Wormlink (como o `duck` do Cyberduck). Usa os mesmos servidores,
/// senhas do Chaves e chaves de servidor conhecidas do app.
nonisolated(unsafe) let usage = """
uso: wormlink <comando> [opções] <alvos>

comandos:
  servidores                      lista os servidores salvos no Wormlink
  ls    <alvo>                    lista uma pasta
  get   <alvo> [destino]          baixa um arquivo ou pasta (destino padrão: pasta atual)
  put   <arquivo>… <alvo>         envia arquivos ou pastas
  cat   <alvo>                    escreve o conteúdo de um arquivo na saída
  mkdir <alvo>                    cria uma pasta
  rm    <alvo>                    apaga um arquivo ou pasta (com tudo dentro)
  mv    <alvo> <novo caminho>     move ou renomeia no servidor
  link  <alvo>                    cria um link compartilhado (Dropbox, Drive, OneDrive, Box,
                                  Nextcloud) ou um link temporário de 7 dias (S3)

alvo:
  "Nome do Servidor:/caminho"     um servidor salvo (caminho relativo = a partir da pasta inicial)
  sftp://usuário@host:porta/caminho   ou ftp://, ftps://, dav://, davs://, s3://, smb://…

opções:
  -p, --password <senha>          senha (ou a variável WORMLINK_PASSWORD; servidores salvos usam o Chaves)
  -i, --identity <arquivo>        chave SSH
  -y, --yes                       confia em chaves de servidor e certificados novos sem perguntar
  -q, --quiet                     sem barra de progresso
  -v, --verbose                   mostra o Transcript (comandos do protocolo)
"""

struct Options {
    var password = ProcessInfo.processInfo.environment["WORMLINK_PASSWORD"]
    var identity: String?
    var yes = false
    var quiet = false
    var verbose = false
    var arguments: [String] = []
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("wormlink: \(message)\n".utf8))
    exit(code)
}

func parse(_ raw: [String]) -> Options {
    var options = Options()
    var iterator = raw.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "-p", "--password":
            guard let value = iterator.next() else { fail("falta a senha depois de \(argument)") }
            options.password = value
        case "-i", "--identity":
            guard let value = iterator.next() else { fail("falta o arquivo depois de \(argument)") }
            options.identity = value
        case "-y", "--yes": options.yes = true
        case "-q", "--quiet": options.quiet = true
        case "-v", "--verbose": options.verbose = true
        case "-h", "--help": print(usage); exit(0)
        default: options.arguments.append(argument)
        }
    }
    return options
}

// MARK: Servidores e alvos

nonisolated(unsafe) let defaults = UserDefaults(suiteName: "app.wormlink.mac")
func savedBookmarks() -> [Bookmark] {
    let drive = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/Wormlink")
    let iCloud = defaults?.bool(forKey: "iCloudSync") == true && FileManager.default.fileExists(atPath: drive.path)
    return BookmarkStore(fileURL: iCloud ? drive.appending(path: "Bookmarks.json") : BookmarkStore.defaultURL).load()
}

struct Target {
    var bookmark: Bookmark
    var path: String?
    var saved: Bool
}

func target(_ text: String) -> Target {
    if text.contains("://") {
        guard let bookmark = Bookmark(address: text) else { fail("endereço inválido: \(text)") }
        let path = URLComponents(string: text)?.percentEncodedPath.removingPercentEncoding ?? ""
        var b = bookmark
        b.path = ""
        return Target(bookmark: b, path: path.isEmpty ? nil : path, saved: false)
    }
    // "Nome:/caminho" — o nome pode ter espaços; o caminho começa no primeiro ":".
    let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let name = String(parts[0])
    let all = savedBookmarks()
    guard let bookmark = all.first(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame })
            ?? all.first(where: { $0.hostname.caseInsensitiveCompare(name) == .orderedSame }) else {
        fail("nenhum servidor salvo chamado “\(name)”. Veja `wormlink servidores` ou use uma URL.")
    }
    let path = parts.count > 1 ? String(parts[1]) : ""
    return Target(bookmark: bookmark, path: path.isEmpty ? nil : path, saved: true)
}

// MARK: Perguntas no terminal

nonisolated(unsafe) let interactive = isatty(STDIN_FILENO) == 1

func ask(_ question: String) -> Bool {
    guard interactive else { return false }
    FileHandle.standardError.write(Data("\(question) [s/N] ".utf8))
    let answer = readLine()?.lowercased() ?? ""
    return answer.hasPrefix("s") || answer.hasPrefix("y")
}

func secret(_ prompt: String) -> String? {
    guard interactive else { return nil }
    var buffer = [CChar](repeating: 0, count: 1024)
    guard let result = readpassphrase(prompt, &buffer, buffer.count, 0) else { return nil }
    return String(cString: result)
}

func trust(_ options: Options) -> ConnectionTrust {
    let yes = options.yes
    return ConnectionTrust(
        hostKey: { challenge in
            if yes && !challenge.changed { return true }
            let warning = challenge.changed ? "ATENÇÃO: a chave de \(challenge.host) MUDOU desde a última conexão." : "Servidor novo: \(challenge.host)."
            return ask("\(warning)\nChave \(challenge.keyType) \(challenge.fingerprint). Confiar?")
        },
        certificate: { challenge in
            yes || ask("O certificado de \(challenge.host) não é confiável (\(challenge.reason)).\n\(challenge.summary)\n\(challenge.fingerprint)\nConfiar?")
        },
        passphrase: { request in secret("Frase secreta de \((request.keyPath as NSString).lastPathComponent): ").map { ($0, false) } },
        openBrowser: { _ in },
        interactive: { challenge in
            if !challenge.instruction.isEmpty { FileHandle.standardError.write(Data((challenge.instruction + "\n").utf8)) }
            var answers: [String] = []
            for prompt in challenge.prompts {
                if prompt.echo {
                    FileHandle.standardError.write(Data(prompt.text.utf8))
                    answers.append(readLine() ?? "")
                } else {
                    guard let answer = secret(prompt.text) else { return nil }
                    answers.append(answer)
                }
            }
            return answers
        })
}

func connect(_ target: Target, _ options: Options) async -> any FileSystem {
    var bookmark = target.bookmark
    if let identity = options.identity { bookmark.keyFile = (identity as NSString).expandingTildeInPath }
    var password = options.password ?? (target.saved ? Keychain.password(for: bookmark) : nil)
    for attempt in 0..<3 {
        do {
            return try await Connector.connect(bookmark, password: password, trust: trust(options))
        } catch WormlinkError.authenticationFailed where attempt < 2 && interactive {
            let who = bookmark.username.isEmpty ? bookmark.hostname : "\(bookmark.username)@\(bookmark.hostname)"
            if attempt > 0 { FileHandle.standardError.write(Data("Senha incorreta.\n".utf8)) }
            password = secret("Senha de \(who): ")
            if password == nil { break }
        } catch {
            fail(error.localizedDescription)
        }
    }
    fail("não foi possível entrar em \(bookmark.hostname).")
}

func resolve(_ path: String?, in fs: any FileSystem) -> String {
    guard let path, !path.isEmpty else { return fs.homePath }
    return path.hasPrefix("/") ? RemotePath.normalize(path) : RemotePath.join(fs.homePath, path)
}

func item(at path: String, in fs: any FileSystem) async throws -> FileItem {
    if path == "/" { return FileItem(path: "/", isDirectory: true) }
    let parent = RemotePath.parent(path)
    guard let found = try await fs.list(parent).first(where: { $0.path == RemotePath.normalize(path) }) else {
        throw WormlinkError.notFound(path)
    }
    return found
}

// MARK: Progresso

final class Progress: @unchecked Sendable {
    private let total: Int64
    private let quiet: Bool
    private let lock = NSLock()
    private var done: Int64 = 0
    private var last = Date.distantPast
    private let start = Date()

    init(total: Int64, quiet: Bool) {
        self.total = total
        self.quiet = quiet || isatty(STDERR_FILENO) != 1
    }

    func add(_ bytes: Int64) {
        let (now, value) = lock.withLock { () -> (Bool, Int64) in
            done += bytes
            let now = Date().timeIntervalSince(last) > 0.2
            if now { last = Date() }
            return (now, done)
        }
        if now { draw(value) }
    }

    private func draw(_ value: Int64) {
        guard !quiet else { return }
        let percent = total > 0 ? Int(Double(value) / Double(total) * 100) : 0
        let width = 30
        let filled = total > 0 ? min(width, Int(Double(width) * Double(value) / Double(total))) : 0
        let speed = Double(value) / max(Date().timeIntervalSince(start), 0.001)
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        let line = "\r\(bar) \(percent)%  \(value.formatted(.byteCount(style: .file))) de \(total.formatted(.byteCount(style: .file)))  \(Int64(speed).formatted(.byteCount(style: .file)))/s   "
        FileHandle.standardError.write(Data(line.utf8))
    }

    func finish() {
        guard !quiet else { return }
        draw(lock.withLock { done })
        FileHandle.standardError.write(Data("\n".utf8))
    }
}

// MARK: Comandos

func run() async {
    var raw = Array(CommandLine.arguments.dropFirst())
    guard !raw.isEmpty else { print(usage); exit(2) }
    let command = raw.removeFirst()
    if ["-h", "--help", "help", "ajuda"].contains(command) { print(usage); exit(0) }
    let options = parse(raw)
    let args = options.arguments
    if options.verbose {
        _ = Transcript.shared.observe { line in
            FileHandle.standardError.write(Data("\(line.isReply ? "<" : ">") \(line.text)\n".utf8))
        }
    }

    do {
        switch command {
        case "servidores", "servers":
            for bookmark in savedBookmarks() {
                let address = bookmark.hostname.isEmpty ? bookmark.connectionProtocol.displayName : bookmark.hostname
                print("\(bookmark.displayName)\t\(bookmark.connectionProtocol.rawValue)://\(bookmark.username.isEmpty ? "" : bookmark.username + "@")\(address)\(bookmark.path)")
            }

        case "ls", "list":
            guard args.count == 1 else { fail("uso: wormlink ls <alvo>") }
            let t = target(args[0])
            let fs = await connect(t, options)
            let items = try await fs.list(resolve(t.path, in: fs))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for item in items {
                let size = item.isDirectory ? "-" : (item.size ?? 0).formatted(.byteCount(style: .file))
                let date = item.modified?.formatted(date: .numeric, time: .shortened) ?? ""
                let mode = item.mode.map { FileItem.permissionString($0) } ?? ""
                print([mode, size.padding(toLength: 10, withPad: " ", startingAt: 0), date.padding(toLength: 18, withPad: " ", startingAt: 0),
                       item.name + (item.isDirectory ? "/" : "")].filter { !$0.isEmpty }.joined(separator: "  "))
            }
            await fs.disconnect()

        case "get", "download":
            guard (1...2).contains(args.count) else { fail("uso: wormlink get <alvo> [destino]") }
            let t = target(args[0])
            let fs = await connect(t, options)
            let source = try await item(at: resolve(t.path, in: fs), in: fs)
            let destination = URL(filePath: args.count == 2 ? (args[1] as NSString).expandingTildeInPath : FileManager.default.currentDirectoryPath)
            var isFolder: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isFolder)
            let local = LocalFileSystem()
            let copier = Copier(from: fs, to: local, skip: .none)
            let progress = Progress(total: try await copier.totalSize(of: source), quiet: options.quiet)
            if exists && isFolder.boolValue {
                try await copier.copy(source, into: destination.path, progress: progress.add)
            } else if source.isDirectory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for child in try await fs.list(source.path) { try await copier.copy(child, into: destination.path, progress: progress.add) }
            } else {
                let counter = LastValue()
                try await fs.download(source.path, to: destination) { received in progress.add(counter.delta(received)) }
            }
            progress.finish()
            await fs.disconnect()

        case "put", "upload":
            guard args.count >= 2 else { fail("uso: wormlink put <arquivo>… <alvo>") }
            let t = target(args.last!)
            let files = args.dropLast().map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
            for file in files where !FileManager.default.fileExists(atPath: file.path) { fail("não existe: \(file.path)") }
            let fs = await connect(t, options)
            let remote = resolve(t.path, in: fs)
            let local = LocalFileSystem()
            let items = files.map { url in
                FileItem(path: url.path, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false,
                         size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init))
            }
            let copier = Copier(from: local, to: fs, skip: .default)
            var total: Int64 = 0
            for item in items { total += try await copier.totalSize(of: item) }
            let progress = Progress(total: total, quiet: options.quiet)
            let existing = try? await item(at: remote, in: fs)
            if existing?.isDirectory ?? (remote == fs.homePath) || items.count > 1 {
                for item in items { try await copier.copy(item, into: remote, progress: progress.add) }
            } else {
                // Um arquivo para um caminho novo: envia com esse nome.
                let counter = LastValue()
                try await fs.upload(files[0], to: remote) { sent in progress.add(counter.delta(sent)) }
            }
            progress.finish()
            await fs.disconnect()

        case "cat":
            guard args.count == 1 else { fail("uso: wormlink cat <alvo>") }
            let t = target(args[0])
            let fs = await connect(t, options)
            let temp = FileManager.default.temporaryDirectory.appending(path: "wormlink-cat-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await fs.download(resolve(t.path, in: fs), to: temp) { _ in }
            FileHandle.standardOutput.write(try Data(contentsOf: temp))
            await fs.disconnect()

        case "mkdir":
            guard args.count == 1 else { fail("uso: wormlink mkdir <alvo>") }
            let t = target(args[0])
            let fs = await connect(t, options)
            try await fs.createDirectory(resolve(t.path, in: fs))
            await fs.disconnect()

        case "rm", "delete":
            guard args.count == 1 else { fail("uso: wormlink rm <alvo>") }
            let t = target(args[0])
            let fs = await connect(t, options)
            let found = try await item(at: resolve(t.path, in: fs), in: fs)
            guard found.path != fs.homePath, found.path != "/" else { fail("recusado: não apago a pasta inicial nem a raiz.") }
            try await fs.delete(found)
            await fs.disconnect()

        case "mv", "move":
            guard args.count == 2 else { fail("uso: wormlink mv <alvo> <novo caminho>") }
            let t = target(args[0])
            let fs = await connect(t, options)
            let from = resolve(t.path, in: fs)
            var to = resolve(args[1], in: fs)
            if let folder = try? await item(at: to, in: fs), folder.isDirectory { to = RemotePath.join(to, RemotePath.name(from)) }
            try await fs.move(from, to: to)
            await fs.disconnect()

        case "link", "share":
            guard args.count == 1 else { fail("uso: wormlink link <alvo>") }
            let t = target(args[0])
            let fs = await connect(t, options)
            let path = resolve(t.path, in: fs)
            if let s3 = fs as? S3FileSystem {
                print(try await s3.presignedURL(path, expires: 604_800).absoluteString)
            } else if let sharing = fs as? any SharesLinks, (fs as? WebDAVFileSystem)?.canShareLinks ?? true {
                print(try await sharing.sharedLink(path).absoluteString)
            } else {
                fail("este servidor não cria links compartilhados.")
            }
            await fs.disconnect()

        default:
            fail("comando desconhecido: \(command)\n\n\(usage)", code: 2)
        }
    } catch {
        fail(error.localizedDescription)
    }
}

/// Converte progresso acumulado (total enviado) em incrementos.
final class LastValue: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    func delta(_ value: Int64) -> Int64 { lock.withLock { defer { last = value }; return max(0, value - last) } }
}

WormlinkLogging.configure()
await run()
exit(0)
