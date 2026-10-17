# Dependências incluídas

Cópias locais de bibliotecas com pequenos patches do Wormlink. O commit de origem de cada uma está em `UPSTREAM`.

| Pasta | Origem | Licença | Patch |
|---|---|---|---|
| `Citadel` | github.com/orlandos-nl/Citadel | MIT | `Algorithms/RSASHA2.swift`: chaves RSA assinando com `rsa-sha2-512`. `SSHAuthenticationMethod`: delegado próprio não é descartado após a primeira tentativa; caso keyboard-interactive. `OpenSSHECDSA.swift` (+ casos em `OpenSSHKey.swift`): chaves ECDSA nistp256/384/521. Sem o exemplo de servidor e sem os testes. |
| `swift-nio-ssh` | github.com/Wellz26/swift-nio-ssh (fork do apple/swift-nio-ssh usado pela Citadel) | Apache 2.0 | `NIOSSHUserAuthAlgorithmNaming`: nome de algoritmo na autenticação separado do prefixo da chave. Keyboard-interactive (RFC 4256): mensagens 60/61, oferta com respondedor, máquina de estados. Sem exemplos e testes. |
| `swift-nio-ssl` | github.com/apple/swift-nio-ssl 2.37.5 | Apache 2.0 | `ClientSessionCache.swift` + `NIOSSLContext.clientSessionCache`: conexões criadas pelo contexto retomam a primeira sessão TLS (FTPS exige isso nas conexões de dados). Só a biblioteca: sem exemplos, benchmarks e testes. |
