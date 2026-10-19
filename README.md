# Wormlink

**English** · [Português](README.pt-BR.md)

A remote file client for macOS 26+, built in Swift/SwiftUI with Liquid Glass. Connect. Explore. Transfer.
Free software under the GPL-3 (see `LICENSE` and `THIRD_PARTY_NOTICES.md`).

- **Features**: a Swift reimplementation of Cyberduck (reference clone in `Reference/cyberduck`, outside the build).
- **Design**: Transmit's layout (map in `../Clones/Transmit/SPEC.md`): two sides, Places, servers with icons, Quick Connect, in-pane server editor, inspector.

## Build and test

```sh
./build-app.sh            # build/Wormlink.app (universal, ad hoc signature)
./build-app.sh --install  # and copies it to /Applications
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The integration tests run against local servers. Each variable turns on a group of tests:

```sh
scripts/test-servers/start.sh /tmp/wormlink-servers     # SFTP, FTP/FTPS, WebDAV and S3 (another terminal)
WORMLINK_SERVERS=/tmp/wormlink-servers \
WORMLINK_AZURITE=1 WORMLINK_SWIFT=1 WORMLINK_SMB=1 WORMLINK_KBDINT=1 \
WORMLINK_MOTO=127.0.0.1:5055 WORMLINK_AGENT=/path/to/ssh-agent.sock WORMLINK_BONJOUR=1 \
WORMLINK_PYCRYPTOMATOR=/path/to/venv/bin/python \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

`WORMLINK_PYCRYPTOMATOR` points to a Python with `pip install pycryptomator`: the vault test creates and reads vaults both ways to check compatibility with another implementation.

Translations: Portuguese is the source language and `Resources/en.lproj` holds English. `scripts/check-translations.sh` lists new strings that still lack a translation.

In debug builds, `WORMLINK_PREVIEW=editor|quick|password|search|settings|transfers|bonjour|columns|gallery|single|inspector|vault .build/debug/Wormlink` opens those screens directly (for screenshots).

## Protocols

| Protocol | Implementation |
|---|---|
| SFTP | Citadel + SwiftNIO SSH (patched). Ed25519, ECDSA and RSA (`rsa-sha2-512`) keys, SSH agent, `~/.ssh/config` with ProxyJump, keyboard-interactive (2FA). Checks `known_hosts` (hashed too). Parallel reads and writes. |
| FTP / FTPS | SwiftNIO + NIOSSL. Explicit or implicit TLS, EPSV/PASV, MLSD or LIST (Unix and Windows), REST/APPE, MFMT, HASH/XSHA256/XMD5 checksums. Per server: name encoding, MLSD, timeout and ASCII mode by extension. |
| WebDAV | URLSession: PROPFIND, MKCOL, MOVE, DELETE, GET and PUT, with Basic and Digest. Nextcloud and ownCloud ready. |
| S3 | SigV4, AWS CLI profiles, AssumeRole with MFA, per-bucket region, multipart, compatibles (Wasabi, R2, B2, Spaces…). Signed URL, ACL, storage class, encryption, metadata, versions, Requester Pays, Transfer Acceleration, lifecycle and CloudFront. |
| SMB | The macOS SMB client (NetFS), mounted in a private folder. Reuses shares that are already mounted. |
| Azure Blob, OpenStack Swift, Backblaze B2 | Shared key/SAS, Keystone v3/v2/TempAuth, B2's S3 API. |
| Dropbox, Google Drive, OneDrive, SharePoint, Box | OAuth with PKCE (each provider's Client ID goes in Settings › Clouds). |

Untrusted TLS certificates (FTPS, WebDAV) go through the system's SecTrust. If the user accepts one, it is remembered.

## Features

- **Browsing**: two sides (Mac ↔ server or server ↔ server) and tabs (⌘T). A list with expandable subfolders and an icon mode. Places per server (drag folders onto the bar). Folder Linking.
- **Transfers**: drag between the sides or from Finder, with a queue, progress and cancelling.
- **Files**: edit remote files in an external app, re-uploaded on save. Quick Look (space) and Get Info with permissions. Copy URL from the root URL. Open in Terminal, including over SSH.
- **Servers**: import of Cyberduck `.duck` bookmarks. Passwords in the Keychain, shared with Cyberduck. History and the `wormlink://bookmark/<id>` link.

## Layout

- `Sources/WormlinkCore`: protocols, bookmarks, trust (SSH/TLS) and copying between file systems.
- `Sources/Wormlink`: SwiftUI app (`MainWindow`, `FilesPane`, `ServersPane`, `ServerEditor`, `InspectorView`).
- `Vendor/`: Citadel and swift-nio-ssh with RSA SHA-2 patches (see `Vendor/README.md`).
- `Resources/AppIcon.icon`: Icon Composer icon; the art layer is generated from `Resources/AppIcon-source.png` by `scripts/make-icon-art.swift`.

## What's new (phases 1–8)

- **Sync** with a preview of the changes, deleting orphans, comparison criteria, time zone offset and rules to ignore files.
- **Transfers**: resume, a question when the file already exists, a limit on simultaneous transfers, "try again", speed and time remaining, preserved dates and notifications.
- **Transcript**: a window with the protocol log, opened with ⇧⌘L.
- **SSH**: keys with a passphrase, kept in the Keychain.
- **Servers**: groups and bookmark sync through iCloud Drive.
- **Built-in text editor**, with encoding detection.
- **Droplets** and the `wormlink://bookmark|upload|mount` scheme.
- **Shortcuts**: Upload, Download, Sync and Open Server actions (the metadata is generated in `build-app.sh`).
- **Clouds**: Dropbox, Google Drive and OneDrive (OAuth with PKCE; each provider's Client ID goes in Settings › Clouds).
- **Wormlink Disk**: a File Provider extension that mounts servers in Finder. It has to be turned on once in System Settings.

## What's new (stages 1–4)

- **Bonjour**: SFTP, FTP, WebDAV and SMB servers on the local network show up on their own in the "Bonjour" group.
- **Import and export**: servers from Cyberduck, Transmit, FileZilla and WinSCP; `.wormlinkservers` backup (passwords optional).
- **SSH keys** (Settings › Keys): list, generate, import, copy the public key and "Install Public Key on Server…".
- **Per-server settings** (editor › Advanced): timeout, encoding, MLSD, ASCII mode, notes and S3 defaults.
- **S3 in Get Info**: temporary link (1 h, 1 day, 7 days), storage class, encryption, access, metadata and versions (restore and download). On the bucket: versioning, Requester Pays, acceleration, lifecycle and CloudFront (create, invalidate, turn on and off).
- **Views**: list, icons, columns and gallery (⌘1–⌘4). One pane or two (⌘\).
- **Shared links**: "Copy Shared Link" on Dropbox, Google Drive, OneDrive/SharePoint, Box and Nextcloud/ownCloud (OCS API). Anyone already signed in to Dropbox needs to sign in again to grant the sharing permission.
- **Command line**: `wormlink` (in `Contents/SharedSupport/bin`, installable from the Wormlink menu). Commands `servidores`, `ls`, `get`, `put`, `cat`, `mkdir`, `rm`, `mv` and `link`, with the app's servers and passwords.
- **AppleScript**: `server names`, `connect`, `list`, `upload` and `download`.
- **System**: the Finder service "Send with Wormlink…", servers in Spotlight and Handoff of the open folder (Handoff between Macs requires signing with a Team ID).

## What's new (stage 5)

- **English**: the interface follows the system language (Portuguese or English).
- **Cryptomator vaults** (format 8, and 7 for reading and writing): opening a vault's folder shows "Unlock…". Inside, names and contents are encrypted and decrypted on the fly, on any protocol. "New Encrypted Vault…" (File or the pane menu) creates a vault compatible with Cryptomator and Cyberduck. The password can be kept in the Keychain.

## Out of reach without an Apple Developer account

Notarization with a Developer ID and automatic updates (Sparkle needs a hosted feed and signing keys).
