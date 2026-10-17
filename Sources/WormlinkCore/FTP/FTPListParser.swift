import Foundation

/// Interpreta listagens FTP: MLSD (RFC 3659) e `LIST` nos formatos Unix e Windows/IIS,
/// os mesmos que o Cyberduck reconhece na prática.
enum FTPListParser {
    private static let posix = Locale(identifier: "en_US_POSIX")

    // MARK: MLSD — "type=file;size=123;modify=20260101120000;UNIX.mode=0644; nome"

    static func mlsd(_ line: String, in dir: String) -> FileItem? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[line.index(after: space)...])
        var facts: [String: String] = [:]
        for fact in line[..<space].split(separator: ";") {
            let pair = fact.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { facts[pair[0].lowercased()] = String(pair[1]) }
        }
        let type = facts["type"]?.lowercased() ?? "file"
        guard type != "cdir" && type != "pdir" else { return nil }
        let isLink = type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink")
        let isDir = type == "dir" || (isLink && facts["type"]?.hasSuffix("dir") == true)
        return FileItem(path: RemotePath.join(dir, name), isDirectory: isDir, isSymlink: isLink,
                        size: isDir ? nil : facts["size"].flatMap(Int64.init),
                        modified: facts["modify"].flatMap(mlsdDate),
                        // Alguns servidores (pyftpdlib) escrevem "0o640".
                        mode: facts["unix.mode"].flatMap { UInt16($0.replacingOccurrences(of: "0o", with: ""), radix: 8) },
                        owner: facts["unix.ownername"] ?? facts["unix.owner"],
                        group: facts["unix.groupname"] ?? facts["unix.group"])
    }

    static let mlsdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    static func mlsdDate(_ text: String) -> Date? { mlsdFormatter.date(from: String(text.prefix(14))) }

    // MARK: LIST

    static func list(_ line: String, in dir: String) -> FileItem? {
        unix(line, in: dir) ?? windows(line, in: dir)
    }

    /// `drwxr-xr-x  2 dono grupo  4096 Jan  1 12:00 nome` (ou com ano no lugar da hora).
    static func unix(_ line: String, in dir: String) -> FileItem? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 8, let kind = fields[0].first, "-dlbcps".contains(kind), fields[0].count >= 10 else { return nil }
        // Acha o mês: o nome começa 3 campos depois dele.
        guard let monthIndex = fields.indices.dropFirst(3).first(where: { months[fields[$0].lowercased()] != nil }),
              monthIndex + 3 < fields.count, let size = Int64(fields[monthIndex - 1]) else { return nil }
        // O nome é tudo depois do campo de hora/ano, preservando espaços.
        var cursor = line.startIndex
        for i in 0...(monthIndex + 2) {
            let r = line.range(of: fields[i], range: cursor..<line.endIndex)!
            cursor = r.upperBound
        }
        var name = String(line[cursor...].drop(while: { $0 == " " }))
        guard !name.isEmpty else { return nil }
        var target: String?
        if kind == "l", let arrow = name.range(of: " -> ") {
            target = String(name[arrow.upperBound...])
            name = String(name[..<arrow.lowerBound])
        }
        let date = unixDate(month: String(fields[monthIndex]), day: String(fields[monthIndex + 1]), timeOrYear: String(fields[monthIndex + 2]))
        var item = FileItem(path: RemotePath.join(dir, name), isDirectory: kind == "d", isSymlink: kind == "l",
                            size: kind == "d" ? nil : size, modified: date, mode: mode(String(fields[0])),
                            owner: monthIndex >= 4 ? String(fields[2]) : nil, group: monthIndex >= 5 ? String(fields[3]) : nil)
        item.linkTarget = target
        return item
    }

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    static func unixDate(month: String, day: String, timeOrYear: String) -> Date? {
        guard let m = months[month.lowercased()], let d = Int(day) else { return nil }
        var c = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), month: m, day: d)
        if timeOrYear.contains(":") {
            let hm = timeOrYear.split(separator: ":").compactMap { Int($0) }
            guard hm.count == 2 else { return nil }
            c.hour = hm[0]; c.minute = hm[1]
            // Sem ano: é dos últimos 12 meses.
            let now = Date()
            c.year = Calendar(identifier: .gregorian).component(.year, from: now)
            if let date = c.date, date > now.addingTimeInterval(86_400) { c.year! -= 1 }
        } else {
            c.year = Int(timeOrYear)
        }
        return c.date
    }

    static func mode(_ text: String) -> UInt16? {
        let chars = Array(text.dropFirst().prefix(9))
        guard chars.count == 9 else { return nil }
        var mode: UInt16 = 0
        for (i, ch) in chars.enumerated() where ch != "-" {
            let bit = UInt16(1) << UInt16(8 - i)
            if "rwxst".contains(ch) { mode |= bit }
        }
        return mode
    }

    /// `01-15-26  10:30AM       <DIR>          pasta` ou `01-15-26  10:30AM  1234 arquivo.txt`
    static func windows(_ line: String, in dir: String) -> FileItem? {
        let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard fields.count == 4, fields[0].count >= 8, fields[0].contains("-") else { return nil }
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = fields[0].count == 10 ? "MM-dd-yyyy hh:mma" : "MM-dd-yy hh:mma"
        let date = f.date(from: "\(fields[0]) \(fields[1])")
        let name = fields[3].trimmingCharacters(in: .whitespaces)
        if fields[2] == "<DIR>" { return FileItem(path: RemotePath.join(dir, name), isDirectory: true, modified: date) }
        guard let size = Int64(fields[2]) else { return nil }
        return FileItem(path: RemotePath.join(dir, name), isDirectory: false, size: size, modified: date)
    }
}
