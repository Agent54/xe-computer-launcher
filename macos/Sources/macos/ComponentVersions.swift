import Foundation

struct ComponentVersion: Equatable {
    let name: String
    let version: String
}

enum ComponentVersions {
    static func bundled(
        resourceURL: URL?,
        contentsURL: URL?,
        heliumAppURL: URL?,
        darcActivation: DarcProfileBundleActivation? = nil
    ) -> [ComponentVersion] {
        let sourceManifest = jsonObject(at: resourceURL?.appendingPathComponent("sources.json"))
        let darcVersion = ((sourceManifest?["darc"] as? [String: Any])?["version"] as? [String: Any])
            .flatMap(semanticVersion)

        let smolVMValues = lockValues(
            at: resourceURL?.appendingPathComponent("SmolRuntime/SmolVM.lock")
        )
        let composeServerValues = lockValues(
            at: resourceURL?.appendingPathComponent("ComposeServer.lock")
        )
        let composeUIValues = lockValues(
            at: resourceURL?.appendingPathComponent("ComposeUI.lock")
        )

        let workerdManifest = jsonObject(
            at: resourceURL?.appendingPathComponent("Workerd.package.json")
        )
        let workerdVersion = (workerdManifest?["dependencies"] as? [String: Any])?["workerd"] as? String

        let heliumVersion = heliumAppURL.flatMap {
            plistValue(
                "CFBundleShortVersionString",
                at: $0.appendingPathComponent("Contents/Info.plist")
            )
        }
        let sparkleVersion = contentsURL.flatMap {
            plistValue(
                "CFBundleShortVersionString",
                at: $0.appendingPathComponent("Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist")
            )
        }

        let activeDarcBundle: String
        if let darcActivation {
            activeDarcBundle = "\(darcActivation.version) "
                + "(profile \(darcActivation.profileName); "
                + "SHA-256 \(darcActivation.sha256.prefix(12)); "
                + "Chromium registry unchanged)"
        } else {
            activeDarcBundle = "Not activated by launcher"
        }

        return [
            ComponentVersion(name: "Xe Computer", version: darcVersion ?? "Unknown"),
            ComponentVersion(name: "Xe Computer active bundle", version: activeDarcBundle),
            ComponentVersion(name: "Helium", version: heliumVersion ?? "Not installed"),
            ComponentVersion(
                name: "SmolVM",
                version: smolVMValues["SMOLVM_RELEASE_TAG"]
                    ?? smolVMValues["SMOLVM_VERSION"]
                    ?? "Unknown"
            ),
            ComponentVersion(
                name: "Compose Server",
                version: composeServerValues["COMPOSE_SERVER_RELEASE_TAG"] ?? "Unknown"
            ),
            ComponentVersion(
                name: "Compose UI",
                version: composeUIValues["COMPOSE_UI_RELEASE_TAG"] ?? "Unknown"
            ),
            ComponentVersion(name: "workerd", version: workerdVersion ?? "Unknown"),
            ComponentVersion(name: "Sparkle", version: sparkleVersion ?? "Unknown")
        ]
    }

    static func aboutText(for components: [ComponentVersion]) -> String {
        (["Components"] + components.map { "\($0.name): \($0.version)" }).joined(separator: "\n")
    }

    private static func jsonObject(at url: URL?) -> [String: Any]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func semanticVersion(_ value: [String: Any]) -> String? {
        guard let major = integer(value["major"]),
              let minor = integer(value["minor"]),
              let patch = integer(value["patch"]) else {
            return nil
        }
        return "\(major).\(minor).\(patch)"
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func lockValues(at url: URL?) -> [String: String] {
        guard let url, let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return contents.split(whereSeparator: \Character.isNewline).reduce(into: [:]) { values, line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { return }
            values[key] = value
        }
    }

    private static func plistValue(_ key: String, at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any] else {
            return nil
        }
        return values[key] as? String
    }
}
