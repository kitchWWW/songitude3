import Foundation

/// Discovers the sound-walk bundles baked into the app at build time.
///
/// The `import_experiences.sh` build phase unzips every `.zip` in `Experiences/` into
/// `<App>.app/Bundled/<name>/`. Each such folder holds a `map.json`, an `audio/` folder and
/// optional album art. This loads them at launch.
enum ExperienceLibrary {

    static func loadAll() -> [Experience] {
        guard let resURL = Bundle.main.resourceURL else { return [] }
        let bundledDir = resURL.appendingPathComponent("Bundled", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: bundledDir,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else {
            return []
        }

        var result: [Experience] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let mapURL = dir.appendingPathComponent("map.json")
            guard let data = try? Data(contentsOf: mapURL) else { continue }
            do {
                let map = try JSONDecoder().decode(SoundMap.self, from: data)
                result.append(Experience(id: dir.lastPathComponent, directory: dir, map: map))
            } catch {
                print("[ExperienceLibrary] failed to decode \(mapURL.lastPathComponent): \(error)")
            }
        }
        return result
    }
}
