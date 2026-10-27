import Foundation
import NaturalLanguage

/// The system's sentence embeddings (NaturalLanguage, offline) for the semantic part of memory relevance.
enum MemoryEmbedding {
    private static let lock = NSLock()
    private static var models: [NLLanguage: NLEmbedding?] = [:]
    /// Vectors by language and text; memory texts rarely change, so each is computed once.
    private static var vectors: [String: [Double]] = [:]

    /// 1 − cosine distance between `query` and each text, in the dominant language of all of them; nil when the system
    /// has no sentence embedding for that language or a text cannot be embedded.
    static func similarities(_ query: String, _ texts: [String]) -> [Double]? {
        lock.lock()
        defer { lock.unlock() }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(([query] + texts.prefix(20)).joined(separator: "\n"))
        guard let language = recognizer.dominantLanguage else { return nil }
        if models[language] == nil { models[language] = NLEmbedding.sentenceEmbedding(for: language) }
        guard let model = models[language] ?? nil else { return nil }
        func vector(_ text: String) -> [Double]? {
            let key = language.rawValue + "\u{1}" + text
            if let v = vectors[key] { return v }
            guard let v = model.vector(for: text) else { return nil }
            if vectors.count > 4000 { vectors.removeAll() }
            vectors[key] = v
            return v
        }
        guard let q = vector(query) else { return nil }
        var result: [Double] = []
        for text in texts {
            guard let v = vector(text) else { return nil }
            var dot = 0.0, nq = 0.0, nv = 0.0
            for i in 0..<min(q.count, v.count) { dot += q[i] * v[i]; nq += q[i] * q[i]; nv += v[i] * v[i] }
            result.append(nq > 0 && nv > 0 ? dot / (nq.squareRoot() * nv.squareRoot()) : 0)
        }
        return result
    }
}
