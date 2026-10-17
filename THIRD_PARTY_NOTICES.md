# Avisos de terceiros

O Wormlink é distribuído sob a GNU General Public License v3 (arquivo `LICENSE`).

## Cyberduck
Funcionalidades e comportamento de protocolos (identificadores de protocolo, formato dos favoritos `.duck`,
senhas no Chaves, MLSD/`OPTS MLST`, listagem via `CWD` + `LIST`, multipart do S3, edição remota) foram
reimplementados em Swift a partir do Cyberduck — © iterate GmbH, GPL-3.0 — https://cyberduck.io

## Design
Layout inspirado no Transmit, da Panic Inc. (https://panic.com/transmit). Nenhum recurso gráfico ou código
do Transmit é usado.

## Bibliotecas
| Biblioteca | Licença |
|---|---|
| Citadel (Joannis Orlandos) — cópia com patch em `Vendor/Citadel` | MIT |
| swift-nio-ssh (Apple; fork Wellz26) — cópia com patch em `Vendor/swift-nio-ssh` | Apache 2.0 |
| SwiftNIO SSL (Apple) — cópia com patch em `Vendor/swift-nio-ssl` | Apache 2.0 |
| SwiftNIO, swift-crypto, swift-log, swift-atomics, swift-collections, swift-system, swift-asn1 (Apple) | Apache 2.0 |
| BigInt (Károly Lőrentey) | MIT |
| BoringSSL (Google), via swift-nio-ssl e swift-crypto | OpenSSL / ISC |
