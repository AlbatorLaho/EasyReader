import AVFoundation
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPronunciationsView: View {
    @Default(.pronunciations) private var pronunciations
    @State private var selection: Pronunciation.ID?
    @State private var previewText = "I like GUI apps, qty 2."
    @State private var importResult: ImportResult?

    @MainActor private static let previewSynthesizer = AVSpeechSynthesizer()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    BackportTable($pronunciations, selection: $selection) {
                        BackportTableColumn("On", value: { $0.enabled ? 0 : 1 }) { $rule in
                            Toggle("Enabled", isOn: $rule.enabled).labelsHidden()
                        }
                        .width(32)
                        BackportTableColumn("Text", value: \.search) { $rule in
                            TextField("Text", text: $rule.search).textFieldStyle(.plain)
                        }
                        .width(min: 80, ideal: 200)
                        BackportTableColumn("Speak As", value: \.replace) { $rule in
                            TextField(rule.isPhonetic ? "IPA" : "Replacement", text: $rule.replace).textFieldStyle(.plain)
                        }
                        .width(min: 80, ideal: 200)
                        BackportTableColumn("App", value: { $0.appDomain.map(AppMenu.name(of:)) ?? "" }) { $rule in
                            AppMenu(bundleID: $rule.appDomain)
                        }
                        .width(min: 90, ideal: 140)
                    }
                    .onMove { pronunciations.move(fromOffsets: $0, toOffset: $1) }
                    .frame(minHeight: 150)

                    HStack(spacing: 4) {
                        Button(action: add) { Image(systemName: "plus").frame(width: 14) }
                            .help("Add a pronunciation")
                        Button(action: removeSelected) { Image(systemName: "minus").frame(width: 14) }
                            .disabled(selection == nil)
                            .help("Remove the selected pronunciation")
                        Spacer()
                        Button("Import from VoiceOver", action: importFromVoiceOver)
                            .help("Add the pronunciations from VoiceOver Utility → Speech → Pronunciation")
                            .alert(item: $importResult) { result in
                                Alert(title: Text(result.title), message: result.message.map(Text.init))
                            }
                    }
                    .padding(.top, 6)
                }
            } label: {
                Label("Pronunciations", systemImage: "character.bubble")
            }

            GroupBox {
                // Always shown so selecting doesn't shift the layout.
                RuleOptions(rule: binding(for: selection))
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Sample text", text: $previewText)
                        Button(action: speakPreview) { Image(systemName: "play.fill") }
                            .help("Speak the preview with the current voice settings")
                    }
                    Text(previewSpoken.text.isEmpty ? " " : previewSpoken.text)
                        .foregroundColor(.secondary)
                }
            } label: {
                Label(previewTitle, systemImage: "text.bubble")
            }

            SettingsFooter {
                ResetDefaultsButton(
                    "Delete All Pronunciations…",
                    confirmation: .init(
                        title: "Delete all pronunciations?",
                        message:
                            "\(pronunciations.count == 1 ? "The pronunciation is" : "All \(pronunciations.count) pronunciations are") deleted. This can't be undone.",
                        button: "Delete All Pronunciations",
                        action: {
                            selection = nil
                            Defaults.reset(.pronunciations)
                        }),
                    isEnabled: !pronunciations.isEmpty)
            }
        }
    }

    private var previewRules: [Pronunciation] {
        let domain = binding(for: selection)?.wrappedValue.appDomain
        return pronunciations.filter { $0.enabled && ($0.appDomain == nil || $0.appDomain == domain) }
    }

    private var previewSpoken: SpokenText {
        SpokenText(previewText, applying: previewRules)
    }

    private var previewTitle: String {
        guard let domain = binding(for: selection)?.wrappedValue.appDomain else { return "Preview" }
        return "Preview in \(AppMenu.name(of: domain))"
    }

    private func binding(for id: Pronunciation.ID?) -> Binding<Pronunciation>? {
        guard let id, let current = pronunciations.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { pronunciations.first { $0.id == id } ?? current },
            set: { newValue in
                guard let index = pronunciations.firstIndex(where: { $0.id == id }) else { return }
                pronunciations[index] = newValue
            }
        )
    }

    private func add() {
        let rule = Pronunciation(search: "", replace: "")
        pronunciations.append(rule)
        selection = rule.id
    }

    private func removeSelected() {
        guard let selection, let index = pronunciations.firstIndex(where: { $0.id == selection }) else { return }
        pronunciations.remove(at: index)
        self.selection = pronunciations.isEmpty ? nil : pronunciations[min(index, pronunciations.count - 1)].id
    }

    private func importFromVoiceOver() {
        guard let rules = Pronunciation.voiceOverPronunciations() else {
            importResult = ImportResult(title: "Couldn't Read VoiceOver Pronunciations", message: "VoiceOver's preferences weren't found.")
            return
        }
        let new = rules.filter { rule in !pronunciations.contains { $0.matchesRule(of: rule) } }
        pronunciations.append(contentsOf: new)
        importResult = ImportResult(
            title: new.isEmpty ? "No New Pronunciations" : "Imported \(new.count) Pronunciation\(new.count == 1 ? "" : "s")",
            message: new.isEmpty
                ? "All \(rules.count) of VoiceOver's pronunciations are already in the list."
                : rules.count == new.count ? nil : "\(rules.count - new.count) already in the list were skipped."
        )
    }

    private func speakPreview() {
        let spoken = previewSpoken
        let utterance = AVSpeechUtterance(spoken)
        Self.previewSynthesizer.stopSpeaking(at: .immediate)
        Self.previewSynthesizer.speak(utterance)
    }

    private struct ImportResult: Identifiable {
        let id = UUID()
        let title: String
        let message: String?
    }
}

private struct RuleOptions: View {
    let rule: Binding<Pronunciation>?

    private static let placeholder = Pronunciation(search: "", replace: "")

    var body: some View {
        let rule = self.rule ?? .constant(Self.placeholder)
        let isEnabled = self.rule != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 20) {
                Toggle("Ignore case", isOn: rule.ignoreCase)
                    .disabled(!isEnabled)
                Toggle("Whole words only", isOn: rule.wholeWord)
                    .help("Don't match inside words, e.g. “GUI” in “GUIDE”")
                    .disabled(!isEnabled)
                Toggle("Regular expression", isOn: rule.isRegex)
                    .help("Text is an ICU regular expression; Speak As can use $1, $2… for captured groups")
                    .disabled(!isEnabled)
                Toggle("Phonetic (IPA)", isOn: rule.isPhonetic)
                    .disabled(!isEnabled)
                    .info("IPA spells out exactly how the matched text should sound.") { IPAInfo() }
            }
            // One line in every state, so the box keeps its height.
            Group {
                if !isEnabled {
                    Text("Select a pronunciation to change its options.")
                        .foregroundColor(.secondary)
                } else if let error = regexError(rule.wrappedValue) {
                    Text("\(Image(systemName: "exclamationmark.triangle.fill")) \(error)")
                        .foregroundColor(.red)
                } else {
                    Text(hint(rule.wrappedValue))
                        .foregroundColor(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func regexError(_ rule: Pronunciation) -> String? {
        guard rule.isRegex, !rule.search.isEmpty else { return nil }
        do {
            _ = try rule.regularExpression()
            return nil
        } catch {
            return "Invalid regular expression"
        }
    }

    private func hint(_ rule: Pronunciation) -> String {
        rule.isPhonetic
            ? "Speak As holds IPA; the matched text is kept (and highlighted) as is, just pronounced from it."
            : "Matches are replaced in one pass: the earliest, then longest match wins."
    }
}

private struct IPAInfo: View {
    var body: some View {
        Group {
            Text("IPA (International Phonetic Alphabet)").font(.headline)
            Text(
                "IPA writes down exactly how a word sounds, one symbol per sound. With this option on, Speak As holds IPA instead of replacement text, and the voice pronounces the matched text from it. Useful for names and words a voice gets wrong."
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("tomato  →  təˈmɑːtəʊ  (British)")
                Text("tomato  →  təˈmeɪɾoʊ  (American)")
            }
            .font(.system(.body, design: .monospaced))
            Text(
                "Most dictionaries list a word's IPA between slashes, e.g. /təˈmɑːtəʊ/ on Wiktionary; copy it without the slashes. ˈ marks the stressed syllable. Use the preview's play button to check how it sounds with your voice."
            )
            .foregroundColor(.secondary)
        }
    }
}

private struct AppMenu: View {
    @Binding var bundleID: String?

    // LaunchServices lookups cost ~15 ms each, and every row's menu lists every app.
    private static var names: [String: String] = [:]
    private static var cachedApps: [String]?

    var body: some View {
        Menu {
            Button("All Apps") { bundleID = nil }
            Divider()
            ForEach(Self.runningApps(), id: \.self) { id in
                Button(Self.name(of: id)) { bundleID = id }
            }
            Divider()
            Button("Other…", action: chooseApp)
        } label: {
            Text(bundleID.map(Self.name(of:)) ?? "All Apps")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        bundleID = id
    }

    static func name(of bundleID: String) -> String {
        if let name = names[bundleID] { return name }
        var name = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
        }
        names[bundleID] = name
        return name
    }

    /// Sorted by name; kept for one main-actor turn, in which every row's menu asks.
    static func runningApps() -> [String] {
        if let cachedApps { return cachedApps }
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
        let apps = Array(Set(ids)).sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
        cachedApps = apps
        DispatchQueue.main.async { cachedApps = nil }
        return apps
    }
}
