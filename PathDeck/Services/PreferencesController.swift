import Foundation
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class PreferencesController {
    let store: PreferencesStore
    var value = AppPreferences()
    var notice: String?
    private var saveTask: Task<Void, Never>?
    private var revision = 0
    private var persisted: AppPreferences?
    init(store: PreferencesStore) { self.store = store }
    func load(migrateLegacy: Bool) async {
        let result = await store.load(); value = result.preferences; notice = result.notice
        if result.missing && migrateLegacy {
            value.favorites = UserDefaults.standard.stringArray(forKey: "PathDeck.favorites")
            value.windowsFriendly = UserDefaults.standard.object(forKey: "PathDeck.windowsFriendly") as? Bool ?? true
        }
        persisted = value.sanitized()
    }
    func changed() {
        if value.sanitized() == persisted { saveTask?.cancel(); return }
        revision += 1; let stamp = revision
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard let self, self.revision == stamp else { return }
                let snapshot = self.value.sanitized()
                try await self.store.save(snapshot); self.persisted = snapshot
            } catch is CancellationError {} catch { self?.notice = "设置保存失败：\(error.localizedDescription)" }
        }
    }
    func flush() async {
        saveTask?.cancel(); saveTask = nil
        do { let snapshot = value.sanitized(); try await store.save(snapshot); persisted = snapshot } catch { notice = "设置保存失败：\(error.localizedDescription)" }
    }
}
