import Foundation

/// Keep only a few encoded previews. Full-size historical results stay on the bridge
/// until explicitly loaded or deleted; scrolling must not accumulate all of them in RAM.
struct CandidatePreviewCache {
    private var values: [String: Data] = [:]
    private var order: [String] = []
    let byteLimit: Int
    let countLimit: Int
    init(byteLimit: Int = 64 * 1024 * 1024, countLimit: Int = 4) {
        self.byteLimit = max(0, byteLimit); self.countLimit = max(0, countLimit)
    }
    var byteCount: Int { values.values.reduce(0) { $0 + $1.count } }
    var count: Int { values.count }
    subscript(key: String) -> Data? {
        get { values[key] }
        set {
            values.removeValue(forKey: key); order.removeAll { $0 == key }
            guard let data = newValue, data.count <= byteLimit, countLimit > 0 else { return }
            values[key] = data; order.append(key)
            while count > countLimit || byteCount > byteLimit {
                values.removeValue(forKey: order.removeFirst())
            }
        }
    }
    mutating func remove(jobID: String) {
        let prefix = jobID + "/"
        values = values.filter { !$0.key.hasPrefix(prefix) }; order.removeAll { $0.hasPrefix(prefix) }
    }
    mutating func removeAll() { values.removeAll(); order.removeAll() }
}
