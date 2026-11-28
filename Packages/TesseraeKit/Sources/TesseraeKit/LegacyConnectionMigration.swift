import Foundation

enum LegacyConnectionMigration {
    static func migrate(directory: URL, suiteName: String?, instance: TesseraeInstance, fence: ConnectionFence) throws {
        let old = instance.id
        let new = instance.storageID
        let standard = UserDefaults.standard
        let shared = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? standard
        for prefix in ["dashboard-order.", "dashboard-collapsed-sections.", "TesseraeRemindersBridge.",
                       "TesseraeHealthBridge.", "device-setup.networks."] {
            move(defaults: standard, from: prefix + old, to: prefix + new)
        }
        let order = "display-order."
        if shared.object(forKey: order + new) == nil {
            if let value = shared.object(forKey: order + old) ?? standard.object(forKey: order + old) {
                shared.set(value, forKey: order + new)
            }
        }
        shared.removeObject(forKey: order + old)
        standard.removeObject(forKey: order + old)
        let preferenceKey = "TesseraeCompanionSendPreferences"
        if let data = shared.data(forKey: preferenceKey) {
            var values = try TesseraeJSON.decoder().decode([String: CompanionSendPreferences].self, from: data)
            if let value = values.removeValue(forKey: old) {
                let renamed = CompanionSendPreferences(instanceID: new, deviceIDs: value.deviceIDs, imageFitMode: value.imageFitMode)
                if shared.data(forKey: preferenceKey + "." + new) == nil {
                    shared.set(try TesseraeJSON.encoder().encode(renamed), forKey: preferenceKey + "." + new)
                }
                shared.set(try TesseraeJSON.encoder().encode(values), forKey: preferenceKey)
            }
        }
        for folder in ["ShareQueue", "LinkShareQueue"] {
            let location = directory.appending(path: folder)
            guard FileManager.default.fileExists(atPath: location.path) else { continue }
            for url in try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
                var record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
                // Legacy records were encoded with convertToSnakeCase and an explicit instanceId coding key.
                let field = record["instance_id"] != nil ? "instance_id" : "instanceId"
                guard record[field] as? String == old else { continue }
                record[field] = new
                record["connection_epoch"] = fence.epoch.uuidString
                try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        let thumbnails = directory.appending(path: "ActivityThumbnails")
        if FileManager.default.fileExists(atPath: thumbnails.path) {
            for url in try FileManager.default.contentsOfDirectory(at: thumbnails, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
                var record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
                let field = record["instance_id"] != nil ? "instance_id" : "instanceId"
                guard record[field] as? String == old else { continue }
                record[field] = new
                let stem = url.deletingPathExtension().lastPathComponent
                let renamed = stem.replacingOccurrences(of: fileToken(old) + "--", with: fileToken(new) + "--")
                let image = thumbnails.appending(path: stem + ".jpg")
                let newImage = thumbnails.appending(path: renamed + ".jpg")
                if FileManager.default.fileExists(atPath: image.path), !FileManager.default.fileExists(atPath: newImage.path) {
                    try FileManager.default.copyItem(at: image, to: newImage)
                }
                try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    .write(to: thumbnails.appending(path: renamed + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try FileManager.default.removeItem(at: url)
                if FileManager.default.fileExists(atPath: image.path) { try FileManager.default.removeItem(at: image) }
            }
        }
    }

    private static func move(defaults: UserDefaults, from old: String, to new: String) {
        if defaults.object(forKey: new) == nil, let value = defaults.object(forKey: old) {
            if let data = value as? Data,
               var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               object["instanceID"] != nil,
               let separator = new.range(of: "connection-v2-") {
                object["instanceID"] = String(new[separator.lowerBound...])
                defaults.set(try? JSONSerialization.data(withJSONObject: object), forKey: new)
            } else { defaults.set(value, forKey: new) }
        }
        defaults.removeObject(forKey: old)
    }
    private static func fileToken(_ value: String) -> String {
        Data(value.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
