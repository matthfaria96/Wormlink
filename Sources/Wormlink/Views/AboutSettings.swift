import SwiftUI

/// Última aba das Configurações: centrada e discreta, como o Sobre Este Mac.
/// As licenças ficam atrás de um link, numa folha à parte.
struct AboutSettings: View {
    @State private var showLicenses = false

    private static let site = URL(string: "http://witchmymac.com")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return String(localized: "Versão \(marketing) (\(build))")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .padding(.bottom, 18)
                Text(verbatim: "WormLink")
                    .font(.system(size: 24, weight: .semibold))
                Text(version)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)

                Text("Cliente de arquivos remotos para o Mac: SFTP, FTP, WebDAV, S3 e nuvens, em dois painéis.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 460)
                    .padding(.top, 26)

                Text("O WormLink é software livre sob a GNU GPL v3.0. Ele se apoia nos projetos de código aberto listados nas licenças.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .padding(.top, 14)

                HStack(spacing: 18) {
                    Link("witchmymac.com", destination: Self.site)
                        .font(.system(size: 12))
                    Button("Licenças de código aberto") { showLicenses = true }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $showLicenses) { LicensesSheet() }
    }
}

/// As licenças do WormLink e do que ele usa, por inteiro, para que os avisos acompanhem o app.
private struct LicensesSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        var id: String { name }
        let name: String
        let license: String
        let text: String
    }

    private static let mit = """
        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all \
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """

    private static let apache = """
        Licensed under the Apache License, Version 2.0 (the "License"); you may not \
        use this file except in compliance with the License. You may obtain a copy of \
        the License at

            https://www.apache.org/licenses/LICENSE-2.0

        Unless required by applicable law or agreed to in writing, software \
        distributed under the License is distributed on an "AS IS" BASIS, WITHOUT \
        WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the \
        License for the specific language governing permissions and limitations under \
        the License.
        """

    private static let gpl = """
        This program is free software: you can redistribute it and/or modify \
        it under the terms of the GNU General Public License as published by \
        the Free Software Foundation, either version 3 of the License, or \
        (at your option) any later version.

        This program is distributed in the hope that it will be useful, \
        but WITHOUT ANY WARRANTY; without even the implied warranty of \
        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the \
        GNU General Public License for more details.

        Full license text: https://www.gnu.org/licenses/gpl-3.0.html
        """

    private let entries = [
        Entry(name: "WormLink", license: "GNU General Public License v3.0",
              text: "Copyright (C) 2026 Matheus Faria\nSource code: https://github.com/matthfaria96/Wormlink\n\n" + gpl),
        Entry(name: "Cyberduck", license: "GNU General Public License v3.0",
              text: "Copyright (c) iterate GmbH\nhttps://cyberduck.io\n\nProtocol behavior and bookmark formats were reimplemented in Swift from Cyberduck.\n\n" + gpl),
        Entry(name: "Citadel", license: "MIT License",
              text: "Copyright (c) 2022 Orlandos\n\n" + mit),
        Entry(name: "BigInt", license: "MIT License",
              text: "Copyright (c) 2016-2017 Károly Lőrentey\n\n" + mit),
        Entry(name: "SwiftNIO, SwiftNIO SSH, SwiftNIO SSL", license: "Apache License 2.0",
              text: "Copyright (c) Apple Inc. and the SwiftNIO project authors\n\n" + apache),
        Entry(name: "swift-crypto, swift-log, swift-atomics, swift-collections, swift-system, swift-asn1", license: "Apache License 2.0",
              text: "Copyright (c) Apple Inc. and the Swift project authors\n\n" + apache),
        Entry(name: "BoringSSL", license: "OpenSSL / ISC License",
              text: """
              Copyright (c) Google Inc. and the OpenSSL Project authors

              Permission to use, copy, modify, and/or distribute this software for any \
              purpose with or without fee is hereby granted, provided that the above \
              copyright notice and this permission notice appear in all copies.

              THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES \
              WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF \
              MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY \
              SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES \
              WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN \
              ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR \
              IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
              """),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Licenças de código aberto")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("O WormLink usa os projetos de código aberto abaixo. Os avisos de copyright e as licenças ficam aqui, como elas exigem. O layout é inspirado no Transmit, da Panic Inc., sem usar código ou imagens dele.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.name).font(.headline)
                                Text(entry.license)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            Text(entry.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 600, height: 540)
    }
}
