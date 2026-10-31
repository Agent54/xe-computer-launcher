import Foundation
import Darwin

extension ApplicationMaintenance {
    static func archiveData(at dataURL: URL, now: Date = Date(), beforeMove: (String) throws -> Void = { _ in }) throws -> URL {
        try archiveData(in: AnchoredDirectory(dataURL), now: now, beforeMove: beforeMove)
    }

    static func archiveData(in data: AnchoredDirectory, now: Date = Date(), beforeMove: (String) throws -> Void = { _ in }) throws -> URL {
        try data.requirePrivateOwner()
        try data.validate()
        let archives = try AnchoredDirectory(childOf: data, name: "archive", create: true)
        try archives.requirePrivateOwner()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss.SSS"
        let timestamp = formatter.string(from: now)
        var name = timestamp
        var suffix = 1
        while mkdirat(archives.descriptor, name, 0o700) != 0 {
            guard errno == EEXIST else { throw posixFailure() }
            suffix += 1
            name = "\(timestamp)-\(suffix)"
        }
        let destination = try AnchoredDirectory(childOf: archives, name: name)
        var moved: [String] = []
        do {
            for name in try data.names() where name != "archive" {
                let identity = try data.entryIdentity(name)
                try beforeMove(name)
                try data.validate()
                try archives.validate()
                try destination.validate()
                try data.move(name, to: destination, as: name)
                moved.append(name)
                guard try destination.entryIdentity(name) == identity else {
                    throw MaintenanceFailure("An app data entry changed during archival.")
                }
            }
            try data.validate()
            try destination.validate()
        } catch {
            var failures: [String] = []
            for name in moved.reversed() {
                do { try destination.move(name, to: data, as: name) }
                catch { failures.append(name) }
            }
            if failures.isEmpty { _ = unlinkat(archives.descriptor, destination.url.lastPathComponent, AT_REMOVEDIR) }
            throw MaintenanceFailure("App data could not be archived: \(error.localizedDescription)\n\n" +
                (failures.isEmpty ? "Moved entries were restored." : "Some entries remain in \(destination.url.path): \(failures.joined(separator: ", ")).") + " The launcher app was kept.")
        }
        return destination.url
    }

    static func trashApprovedBundle(_ bundle: BundleIdentity,
                                    trashURL: URL = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().appendingPathComponent(".Trash"),
                                    beforeMove: () throws -> Void = {}) throws {
        try bundle.validate()
        guard bundle.contents != nil else { throw MaintenanceFailure("Only an approved .app bundle can be moved to Trash.") }
        let url = URL(fileURLWithPath: bundle.directory.path)
        let parent = try AnchoredDirectory(url.deletingLastPathComponent())
        guard parent.identity.ancestors == Array(bundle.directory.ancestors.dropLast()) else {
            throw MaintenanceFailure("The approved bundle's parent changed.")
        }
        let trash = try AnchoredDirectory(trashURL, create: true)
        try trash.requirePrivateOwner()
        let destination = "\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).app"
        let stagingName = ".xe-uninstall-\(UUID().uuidString)"
        let staging = try AnchoredDirectory(childOf: parent, name: stagingName, create: true)
        defer { _ = unlinkat(parent.descriptor, stagingName, AT_REMOVEDIR) }
        try beforeMove()
        try parent.validate()
        try trash.validate()
        // Stage and verify the object actually renamed before moving anything
        // into Trash. An app swapped at its original name is restored here.
        try parent.move(url.lastPathComponent, to: staging, as: "app")
        do {
            guard try staging.entryIdentity("app") == bundle.directory.ancestors.last else {
                throw MaintenanceFailure("The approved launcher bundle was replaced before removal.")
            }
            let app = try AnchoredDirectory(childOf: staging, name: "app")
            let contents = try AnchoredDirectory(childOf: app, name: "Contents")
            let executables = try AnchoredDirectory(childOf: contents, name: "MacOS")
            guard contents.identity.ancestors.last == bundle.contents?.ancestors.last,
                  executables.identity.ancestors.last == bundle.executableDirectory.ancestors.last,
                  try contents.entryIdentity("Info.plist") == bundle.info,
                  try executables.entryIdentity(bundle.executableName) == bundle.executable else {
                throw MaintenanceFailure("The approved launcher's contents were replaced before removal.")
            }
            try staging.validate()
            try trash.validate()
            try staging.move("app", to: trash, as: destination)
            guard try trash.entryIdentity(destination) == bundle.directory.ancestors.last else {
                try? trash.move(destination, to: staging, as: "app")
                throw MaintenanceFailure("The approved launcher changed while moving to Trash.")
            }
        } catch {
            do { try staging.move("app", to: parent, as: url.lastPathComponent) }
            catch { throw MaintenanceFailure("The launcher could not be restored to its previous path. It was preserved at \(staging.url.path)/app.") }
            throw error
        }
    }
}
