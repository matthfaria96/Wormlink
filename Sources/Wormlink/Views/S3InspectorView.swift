import SwiftUI
import WormlinkCore

/// Parte S3 do "Obter Informações": objeto (classe, criptografia, ACL, metadados, versões, link assinado)
/// ou bucket (versionamento, requester pays, aceleração, ciclo de vida, CloudFront).
struct S3InspectorSection: View {
    let fs: S3FileSystem
    let item: FileItem
    var section: (String, AnyView) -> AnyView

    var body: some View {
        if item.isDirectory && RemotePath.parent(item.path) == "/" {
            S3BucketPanel(fs: fs, bucket: RemotePath.name(item.path), section: section)
                .id(item.path)
        } else if !item.isDirectory {
            S3ObjectPanel(fs: fs, item: item, section: section)
                .id(item.path)
        }
    }
}

private struct S3ObjectPanel: View {
    let fs: S3FileSystem
    let item: FileItem
    var section: (String, AnyView) -> AnyView
    @State private var info: S3ObjectInfo?
    @State private var saved: S3ObjectInfo?
    @State private var versions: [S3Version] = []
    @State private var error: String?
    @State private var busy = false
    @State private var copied: String?

    var body: some View {
        VStack(spacing: 16) {
            section(String(localized: "Link temporário"), AnyView(shareLink))
            if let info = Binding($info) {
                section("Amazon S3", AnyView(properties(info)))
                section(String(localized: "Metadados"), AnyView(metadata(info)))
            } else if error == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            if versions.count > 1 { section(String(localized: "Versões"), AnyView(versionList)) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let loaded = try await fs.objectInfo(item.path)
            info = loaded
            saved = loaded
            versions = (try? await fs.versions(item.path)) ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var shareLink: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Qualquer pessoa com o link baixa o arquivo, sem conta, até o link expirar.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach([("1 hora", 3600.0), ("1 dia", 86_400.0), ("7 dias", 604_800.0)], id: \.0) { title, seconds in
                    Button(title) { Task { await copyLink(seconds, title) } }
                }
            }
            .controlSize(.small)
            if let copied { Label("Link de \(copied) copiado", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
        }
    }

    private func copyLink(_ seconds: TimeInterval, _ title: String) async {
        do {
            let url = try await fs.presignedURL(item.path, expires: seconds)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            copied = title
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private func properties(_ info: Binding<S3ObjectInfo>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                label(String(localized: "Classe"))
                Picker("", selection: info.storageClass) {
                    ForEach(S3StorageClass.all, id: \.id) { Text($0.title).tag($0.id) }
                    if !S3StorageClass.all.contains(where: { $0.id == info.wrappedValue.storageClass }) {
                        Text(info.wrappedValue.storageClass).tag(info.wrappedValue.storageClass)
                    }
                }
                .labelsHidden()
            }
            GridRow {
                label(String(localized: "Criptografia"))
                Picker("", selection: Binding(get: { info.wrappedValue.encryption ?? "" },
                                              set: { info.wrappedValue.encryption = $0.isEmpty ? nil : $0 })) {
                    ForEach(S3Encryption.all, id: \.id) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
            }
            if info.wrappedValue.encryption == "aws:kms" {
                GridRow {
                    label(String(localized: "Chave KMS"))
                    TextField("", text: Binding(get: { info.wrappedValue.kmsKeyID ?? "" }, set: { info.wrappedValue.kmsKeyID = $0 }),
                              prompt: Text("padrão da conta"))
                }
            }
            if info.wrappedValue.acl != nil {
                GridRow {
                    label(String(localized: "Acesso"))
                    Picker("", selection: Binding(get: { info.wrappedValue.acl ?? .private }, set: { info.wrappedValue.acl = $0 })) {
                        ForEach(S3CannedACL.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            GridRow {
                label(String(localized: "Tipo"))
                TextField("", text: Binding(get: { info.wrappedValue.contentType ?? "" }, set: { info.wrappedValue.contentType = $0 }),
                          prompt: Text("application/octet-stream"))
            }
            GridRow {
                label(String(localized: "Cache"))
                TextField("", text: Binding(get: { info.wrappedValue.cacheControl ?? "" }, set: { info.wrappedValue.cacheControl = $0 }),
                          prompt: Text("max-age=86400"))
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout)
        applyBar
    }

    @ViewBuilder
    private func metadata(_ info: Binding<S3ObjectInfo>) -> some View {
        let keys = info.wrappedValue.metadata.keys.sorted()
        if keys.isEmpty { Text("Nenhum metadado.").font(.caption).foregroundStyle(.secondary) }
        ForEach(keys, id: \.self) { key in
            HStack(spacing: 6) {
                Text(key).font(.callout.monospaced()).frame(width: 80, alignment: .leading).lineLimit(1)
                TextField("", text: Binding(get: { info.wrappedValue.metadata[key] ?? "" }, set: { info.wrappedValue.metadata[key] = $0 }))
                    .textFieldStyle(.roundedBorder)
                Button("Remover", systemImage: "minus.circle") { info.wrappedValue.metadata[key] = nil }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        Button("Adicionar", systemImage: "plus") {
            var name = "chave"
            var n = 1
            while info.wrappedValue.metadata[name] != nil { n += 1; name = "chave\(n)" }
            info.wrappedValue.metadata[name] = ""
        }
        .buttonStyle(.borderless).font(.caption)
        if self.info != saved { applyBar }
    }

    private var applyBar: some View {
        HStack {
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Aplicar") { Task { await apply() } }
                .buttonStyle(.borderedProminent)
                .disabled(info == saved || busy)
        }
    }

    private func apply() async {
        guard let info, let saved else { return }
        busy = true
        defer { busy = false }
        do {
            var properties = info
            properties.acl = nil
            var before = saved
            before.acl = nil
            if properties != before { try await fs.update(item.path, properties) }
            // A cópia sobre si mesmo volta a ACL para privado: reaplica a escolhida.
            if let acl = info.acl, acl != saved.acl || properties != before { try await fs.setACL(item.path, acl) }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var versionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(versions) { version in
                HStack {
                    Image(systemName: version.isDeleteMarker ? "trash" : version.isLatest ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(version.isLatest ? Color.wormlink : .secondary)
                    VStack(alignment: .leading) {
                        Text(version.modified?.formatted(date: .abbreviated, time: .shortened) ?? version.versionID).font(.callout)
                        Text(version.isDeleteMarker ? String(localized: "Apagado") : version.size.map { $0.formatted(.byteCount(style: .file)) } ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !version.isLatest && !version.isDeleteMarker {
                        Menu {
                            Button("Restaurar Esta Versão") { Task { try? await fs.restore(item.path, version: version.versionID); await load() } }
                            Button("Baixar…") { download(version) }
                            Divider()
                            Button("Apagar Versão", role: .destructive) {
                                Task { try? await fs.deleteVersion(item.path, version: version.versionID); await load() }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                    }
                }
            }
        }
    }

    private func download(_ version: S3Version) {
        let panel = NSSavePanel()
        let name = item.name as NSString
        let stamp = version.modified?.formatted(.iso8601.year().month().day()) ?? version.versionID.prefix(8).description
        panel.nameFieldStringValue = name.deletingPathExtension + " (\(stamp))" + (name.pathExtension.isEmpty ? "" : "." + name.pathExtension)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await fs.download(item.path, version: version.versionID, to: url) } catch { self.error = error.localizedDescription }
        }
    }
}

private struct S3BucketPanel: View {
    let fs: S3FileSystem
    let bucket: String
    var section: (String, AnyView) -> AnyView
    @State private var options: S3BucketOptions?
    @State private var lifecycle = S3Lifecycle()
    @State private var distributions: [CloudFrontDistribution] = []
    @State private var invalidation = "/*"
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            if let options {
                section("Bucket", AnyView(bucketToggles(options)))
                section(String(localized: "Ciclo de vida"), AnyView(lifecycleEditor))
                if fs.isAWS { section("CloudFront", AnyView(cloudFront)) }
            } else if error == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            if let message { Label(message, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let loaded = try await fs.bucketOptions(bucket)
            options = loaded
            lifecycle = loaded.lifecycle
            if fs.isAWS { distributions = (try? await fs.distributions(for: bucket)) ?? [] }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ done: String, _ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                message = done
                error = nil
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func bucketToggles(_ options: S3BucketOptions) -> some View {
        Toggle("Guardar versões dos arquivos", isOn: Binding(get: { options.versioning == "Enabled" }, set: { on in
            run(on ? String(localized: "Versionamento ligado") : String(localized: "Versionamento suspenso")) { try await fs.setVersioning(bucket, enabled: on) }
        }))
        Toggle("Quem baixa paga (Requester Pays)", isOn: Binding(get: { options.requesterPays }, set: { on in
            run(String(localized: "Pagamento atualizado")) { try await fs.setRequesterPays(bucket, enabled: on) }
        }))
        if fs.isAWS {
            Toggle("Transfer Acceleration", isOn: Binding(get: { options.acceleration == "Enabled" }, set: { on in
                run(String(localized: "Aceleração atualizada")) { try await fs.setAcceleration(bucket, enabled: on) }
            }))
            Text("Com a aceleração ligada no bucket, ative-a também no editor do servidor para usar o endereço acelerado.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lifecycleEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Mover arquivos depois de", isOn: Binding(get: { lifecycle.transitionDays != nil },
                                                             set: { lifecycle.transitionDays = $0 ? 30 : nil }))
            if lifecycle.transitionDays != nil {
                HStack {
                    TextField("", value: Binding(get: { lifecycle.transitionDays ?? 30 }, set: { lifecycle.transitionDays = max(0, $0) }),
                              format: .number).frame(width: 50)
                    Text("dias para")
                    Picker("", selection: $lifecycle.transitionClass) {
                        ForEach(S3StorageClass.all.filter { $0.id != "STANDARD" && $0.id != "REDUCED_REDUNDANCY" }, id: \.id) {
                            Text($0.title).tag($0.id)
                        }
                    }
                    .labelsHidden()
                }
                .padding(.leading, 20)
            }
            Toggle("Apagar arquivos depois de", isOn: Binding(get: { lifecycle.expirationDays != nil },
                                                              set: { lifecycle.expirationDays = $0 ? 365 : nil }))
            if lifecycle.expirationDays != nil {
                HStack {
                    TextField("", value: Binding(get: { lifecycle.expirationDays ?? 365 }, set: { lifecycle.expirationDays = max(1, $0) }),
                              format: .number).frame(width: 50)
                    Text("dias")
                }
                .padding(.leading, 20)
            }
            HStack {
                Spacer()
                Button("Aplicar") { run("Ciclo de vida salvo") { try await fs.setLifecycle(bucket, lifecycle) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(lifecycle == options?.lifecycle)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var cloudFront: some View {
        VStack(alignment: .leading, spacing: 8) {
            if distributions.isEmpty {
                Text("Nenhuma distribuição usa este bucket.").font(.caption).foregroundStyle(.secondary)
                Button("Criar Distribuição") { run("Distribuição criada (leva alguns minutos para ativar)") { try await fs.createDistribution(for: bucket) } }
            }
            ForEach(distributions) { distribution in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(distribution.enabled ? .green : .secondary).frame(width: 7, height: 7)
                        Text(distribution.domainName).font(.callout).textSelection(.enabled).lineLimit(1)
                    }
                    Text("\(distribution.id) · \(distribution.status == "Deployed" ? "Implantada" : "Em andamento")")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("", text: $invalidation, prompt: Text("/caminho/*")).textFieldStyle(.roundedBorder)
                        Button("Invalidar") {
                            let paths = invalidation.split(separator: " ").map(String.init)
                            run(String(localized: "Invalidação enviada")) { try await fs.invalidate(distribution.id, paths: paths) }
                        }
                    }
                    Button(distribution.enabled ? "Desativar" : "Ativar") {
                        run(distribution.enabled ? String(localized: "Distribuição desativada") : String(localized: "Distribuição ativada")) {
                            try await fs.setDistribution(distribution.id, enabled: !distribution.enabled)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

private func label(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
}
