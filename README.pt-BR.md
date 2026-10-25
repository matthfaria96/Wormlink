# Wormlink

[English](README.md) · **Português**

Cliente de arquivos remotos para macOS 26+, em Swift/SwiftUI com Liquid Glass. Conecte. Explore. Transfira.
Software livre sob a GPL-3 (veja `LICENSE` e `THIRD_PARTY_NOTICES.md`).

- **Funcionalidades**: reimplementação em Swift do Cyberduck (clone de referência em `Reference/cyberduck`, fora do build).
- **Design**: layout do Transmit (mapa em `../Clones/Transmit/SPEC.md`): dois lados, Places, servidores com ícones, Quick Connect, editor de servidor no painel, inspetor.

## Instalar

Escolha um:

1. **Terminal, uma linha (recomendado).** Cole isto no Terminal:
   ```sh
   curl -fsSL https://witchmymac.com/install.sh | bash -s wormlink
   ```
   Ele baixa a versão mais nova do GitHub, confere o SHA-256, instala o Wormlink em Aplicativos e abre. Não aparece aviso do macOS, porque arquivos baixados pelo `curl` não ganham a marca de "baixado da internet". Rode a mesma linha de novo para atualizar. O script é aberto: [install.sh](https://witchmymac.com/install.sh).
2. **Baixe o DMG** em [Releases](https://github.com/matthfaria96/Wormlink/releases) ou em [witchmymac.com](https://witchmymac.com), arraste o Wormlink para Aplicativos e libere uma vez com:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Wormlink.app"
   ```
   Ele só tira daquele app a marca de "baixado da internet".
3. **Baixe o DMG** e libere pelos Ajustes do Sistema: abra o app, clique em OK no aviso e vá em Ajustes do Sistema › Privacidade e Segurança › Abrir Mesmo Assim.

Requer macOS 26 ou posterior.

## Compilar e testar

```sh
./build-app.sh            # build/Wormlink.app (universal, assinatura ad hoc)
./build-app.sh --install  # e copia para /Applications
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Os testes de integração rodam contra servidores locais. Cada variável liga um grupo de testes:

```sh
scripts/test-servers/start.sh /tmp/wormlink-servers     # SFTP, FTP/FTPS, WebDAV e S3 (outro terminal)
WORMLINK_SERVERS=/tmp/wormlink-servers \
WORMLINK_AZURITE=1 WORMLINK_SWIFT=1 WORMLINK_SMB=1 WORMLINK_KBDINT=1 \
WORMLINK_MOTO=127.0.0.1:5055 WORMLINK_AGENT=/caminho/do/ssh-agent.sock WORMLINK_BONJOUR=1 \
WORMLINK_PYCRYPTOMATOR=/caminho/venv/bin/python \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

`WORMLINK_PYCRYPTOMATOR` aponta para um Python com `pip install pycryptomator`: o teste de cofres cria e lê cofres nos dois sentidos para conferir a compatibilidade com outra implementação.

Traduções: o português é a língua de origem e `Resources/en.lproj` traz o inglês. `scripts/check-translations.sh` lista os textos novos ainda sem tradução.

Em compilações de depuração, `WORMLINK_PREVIEW=editor|quick|password|search|settings|transfers|bonjour|columns|gallery|single|inspector|vault .build/debug/Wormlink` abre essas telas direto (para capturas). `WORMLINK_PREVIEW_MAC_NAME` e `WORMLINK_PREVIEW_USER` trocam o nome deste Mac e o do usuário mostrados nos painéis, para capturas sem dados pessoais.

## Protocolos

| Protocolo | Implementação |
|---|---|
| SFTP | Citadel + SwiftNIO SSH (com patches). Chaves Ed25519, ECDSA e RSA (`rsa-sha2-512`), agente SSH, `~/.ssh/config` com ProxyJump, keyboard-interactive (2FA). Verifica `known_hosts` (inclusive em hash). Leituras e escritas em paralelo. |
| FTP / FTPS | SwiftNIO + NIOSSL. TLS explícito ou implícito, EPSV/PASV, MLSD ou LIST (Unix e Windows), REST/APPE, MFMT, checksums HASH/XSHA256/XMD5. Por servidor: codificação dos nomes, MLSD, tempo limite e modo ASCII por extensão. |
| WebDAV | URLSession: PROPFIND, MKCOL, MOVE, DELETE, GET e PUT, com Basic e Digest. Nextcloud e ownCloud prontos. |
| S3 | SigV4, perfis da AWS CLI, AssumeRole com MFA, região por bucket, multipart, compatíveis (Wasabi, R2, B2, Spaces…). URL assinada, ACL, classe, criptografia, metadados, versões, Requester Pays, Transfer Acceleration, ciclo de vida e CloudFront. |
| SMB | Cliente SMB do macOS (NetFS), montado numa pasta privada. Reaproveita compartilhamentos que já estão montados. |
| Azure Blob, OpenStack Swift, Backblaze B2 | Chave compartilhada/SAS, Keystone v3/v2/TempAuth, API S3 do B2. |
| Dropbox, Google Drive, OneDrive, SharePoint, Box | OAuth com PKCE (o Client ID de cada provedor vai em Ajustes › Nuvens). |

Certificados TLS não confiáveis (FTPS, WebDAV) passam pelo SecTrust do sistema. Se o usuário aceitar um, ele fica lembrado.

## Recursos

- **Navegação**: dois lados (Mac ↔ servidor ou servidor ↔ servidor) e abas (⌘T). Lista com subpastas expansíveis e modo ícones. Places por servidor (arraste pastas para a barra). Folder Linking.
- **Transferências**: arraste entre os lados ou do Finder, com fila, progresso e cancelamento.
- **Arquivos**: editar arquivos remotos em app externo, com reenvio ao salvar. Visualização Rápida (espaço) e Obter Informações com permissões. Copiar URL a partir da URL raiz. Abrir no Terminal, inclusive via SSH.
- **Servidores**: importação de favoritos `.duck` do Cyberduck. Senhas no Chaves, compartilhadas com o Cyberduck. Histórico e o link `wormlink://bookmark/<id>`.

## Estrutura

- `Sources/WormlinkCore`: protocolos, favoritos, confiança (SSH/TLS) e cópia entre sistemas de arquivos.
- `Sources/Wormlink`: app SwiftUI (`MainWindow`, `FilesPane`, `ServersPane`, `ServerEditor`, `InspectorView`).
- `Vendor/`: Citadel e swift-nio-ssh com patches de RSA SHA-2 (veja `Vendor/README.md`).
- `Resources/AppIcon.icon`: ícone do Icon Composer; a camada de arte é gerada de `Resources/AppIcon-source.png` por `scripts/make-icon-art.swift`.

## Novidades (fases 1–8)

- **Sincronização** com prévia das mudanças, apagar órfãos, critério de comparação, diferença de fuso e regras para ignorar arquivos.
- **Transferências**: retomada, pergunta quando o arquivo já existe, limite de simultâneas, "tentar de novo", velocidade e tempo restante, datas preservadas e notificações.
- **Transcript**: janela com o log do protocolo, aberta com ⇧⌘L.
- **SSH**: chaves com frase secreta, guardada no Chaves.
- **Servidores**: grupos e sincronização dos favoritos pelo iCloud Drive.
- **Editor de texto embutido**, com detecção de codificação.
- **Droplets** e o esquema `wormlink://bookmark|upload|mount`.
- **Atalhos**: ações de Enviar, Baixar, Sincronizar e Abrir Servidor (os metadados são gerados no `build-app.sh`).
- **Nuvens**: Dropbox, Google Drive e OneDrive (OAuth com PKCE; o Client ID de cada provedor vai em Ajustes › Nuvens).
- **Wormlink Disk**: extensão File Provider que monta servidores no Finder. É preciso ativá-la uma vez em Ajustes do Sistema.

## Novidades (etapas 1–4)

- **Bonjour**: servidores SFTP, FTP, WebDAV e SMB da rede local aparecem sozinhos no grupo "Bonjour".
- **Importar e exportar**: servidores do Cyberduck, Transmit, FileZilla e WinSCP; backup `.wormlinkservers` (senhas opcionais).
- **Chaves SSH** (Ajustes › Chaves): listar, gerar, importar, copiar a pública e "Instalar Chave Pública no Servidor…".
- **Ajustes por servidor** (editor › Avançado): tempo limite, codificação, MLSD, modo ASCII, notas e padrões S3.
- **S3 no Obter Informações**: link temporário (1 h, 1 dia, 7 dias), classe, criptografia, acesso, metadados e versões (restaurar e baixar). No bucket: versionamento, Requester Pays, aceleração, ciclo de vida e CloudFront (criar, invalidar, ligar e desligar).
- **Visualizações**: lista, ícones, colunas e galeria (⌘1–⌘4). Um painel ou dois (⌘\).
- **Links compartilhados**: "Copiar Link Compartilhado" no Dropbox, Google Drive, OneDrive/SharePoint, Box e Nextcloud/ownCloud (API OCS). Quem já tinha entrado no Dropbox precisa entrar de novo para dar a permissão de compartilhamento.
- **Linha de comando**: `wormlink` (em `Contents/SharedSupport/bin`, instalável pelo menu Wormlink). Comandos `servidores`, `ls`, `get`, `put`, `cat`, `mkdir`, `rm`, `mv` e `link`, com os servidores e senhas do app.
- **AppleScript**: `server names`, `connect`, `list`, `upload` e `download`.
- **Sistema**: serviço do Finder "Enviar com o Wormlink…", servidores no Spotlight e Handoff da pasta aberta (o Handoff entre Macs exige assinatura com Team ID).

## Novidades (etapa 5)

- **Inglês**: a interface segue o idioma do sistema (português ou inglês).
- **Cofres do Cryptomator** (formato 8, e 7 para leitura e escrita): ao abrir a pasta de um cofre aparece "Desbloquear…". Lá dentro os nomes e o conteúdo são cifrados e decifrados na hora, em qualquer protocolo. "Novo Cofre Criptografado…" (Arquivo ou menu do painel) cria um cofre compatível com o Cryptomator e o Cyberduck. A senha pode ficar no Chaves.

## Fora do alcance sem conta Apple Developer

Notarização com Developer ID.

## Atualizações

Desde a 0.2.1, o Wormlink se atualiza pelo Sparkle: Wormlink › Verificar Atualizações… (também em Ajustes › Sobre), além de uma verificação diária. O feed é `https://witchmymac.com/appcast/wormlink.xml`; as versões são assinadas com a chave EdDSA do witchmymac. Quem está numa versão anterior instala a 0.2.1 à mão uma vez.
