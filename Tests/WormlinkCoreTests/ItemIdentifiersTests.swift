import Foundation
import Testing
@testable import WormlinkCore

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "ids-\(UUID().uuidString)/ids.json")
}

@Test func itemIdentifiersAreStable() {
    let store = ItemIdentifiers(file: tempFile())
    let a = store.identifier(for: "/docs/a.txt")
    #expect(store.identifier(for: "/docs//a.txt") == a)
    #expect(store.identifier(for: "/docs/b.txt") != a)
    #expect(store.path(for: a) == "/docs/a.txt")
    #expect(store.path(for: "nope") == nil)
}

@Test func itemIdentifiersPersist() {
    let file = tempFile()
    let a = ItemIdentifiers(file: file).identifier(for: "/x/y")
    let reloaded = ItemIdentifiers(file: file)
    #expect(reloaded.path(for: a) == "/x/y")
    #expect(reloaded.identifier(for: "/x/y") == a)
}

@Test func itemIdentifiersFollowMoves() {
    let file = tempFile()
    let store = ItemIdentifiers(file: file)
    let folder = store.identifier(for: "/a/pasta")
    let child = store.identifier(for: "/a/pasta/sub/f.txt")
    let sibling = store.identifier(for: "/a/pastas")
    store.moved(from: "/a/pasta", to: "/b/nova")
    #expect(store.path(for: folder) == "/b/nova")
    #expect(store.path(for: child) == "/b/nova/sub/f.txt")
    #expect(store.path(for: sibling) == "/a/pastas")
    #expect(ItemIdentifiers(file: file).path(for: child) == "/b/nova/sub/f.txt")
}

@Test func itemIdentifiersDropRemoved() {
    let store = ItemIdentifiers(file: tempFile())
    let folder = store.identifier(for: "/p")
    let child = store.identifier(for: "/p/q")
    let other = store.identifier(for: "/pq")
    store.removed("/p")
    #expect(store.path(for: folder) == nil)
    #expect(store.path(for: child) == nil)
    #expect(store.path(for: other) == "/pq")
    #expect(store.identifier(for: "/p") != folder)
}

@Test func itemIdentifiersIgnoreCorruptFile() throws {
    let file = tempFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{não é json".utf8).write(to: file)
    let store = ItemIdentifiers(file: file)
    #expect(store.path(for: "qualquer") == nil)
    let id = store.identifier(for: "/a")
    #expect(ItemIdentifiers(file: file).path(for: id) == "/a")
}
