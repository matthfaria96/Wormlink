import Foundation
import Testing
@testable import WormlinkCore

@Test func sshConfigFirstValueWins() {
    let config = SSHConfig(text: """
    # global
    ServerAliveInterval 30

    Host web prod-*
        HostName 203.0.113.10
        User deploy
        Port 2200
        IdentityFile ~/.ssh/deploy_ed25519
        ProxyJump bastion

    Host prod-db !prod-db-legacy
        HostName db.%h.internal
        User=dba

    Host *
        User ana
        IdentityFile ~/.ssh/id_ed25519
        IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    """)
    let web = config.resolve("web")
    #expect(web.hostName == "203.0.113.10" && web.user == "deploy" && web.port == 2200 && web.proxyJump == "bastion")
    #expect(web.identityFiles.count == 2 && web.identityFiles[0].hasSuffix("/.ssh/deploy_ed25519"))
    #expect(web.identityAgent?.hasSuffix("com.1password/t/agent.sock") == true)

    let db = config.resolve("prod-db")
    #expect(db.hostName == "203.0.113.10")   // "prod-*" vem antes e ganha
    #expect(db.user == "deploy")

    let other = config.resolve("exemplo.com")
    #expect(other.hostName == nil && other.user == "ana" && other.port == nil)
    #expect(!SSHConfig.matches(["prod-*", "!prod-db-legacy"], "prod-db-legacy"))
}
