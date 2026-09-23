/// Parakeet v3 returns no per-segment language, so transcripts and bundles lose
/// their language tags. Tags the uk/ru/en mix from script and function-word
/// evidence; inconclusive segments stay untagged.
///
/// ponytail: hint, not model output; extend the word lists if other languages need labels.
enum ParakeetLanguage {
    static func tag(_ text: String) -> String? {
        let words = text.lowercased().split { !$0.isLetter && $0 != "'" && $0 != "’" }
        if text.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
            let ukrainian = score(words, markers: "іїєґ", vocabulary: ukrainianWords)
            let russian = score(words, markers: "ыэъё", vocabulary: russianWords)
            guard ukrainian != russian else { return nil }
            return ukrainian > russian ? "uk" : "ru"
        }
        guard words.contains(where: { englishWords.contains(String($0)) }) else { return nil }
        return "en"
    }

    static func tagging(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { segment in
            TranscriptSegment(
                start: segment.start, end: segment.end, text: segment.text,
                language: tag(segment.text)
            )
        }
    }

    private static func score(_ words: [Substring], markers: String, vocabulary: Set<String>) -> Int {
        words.reduce(0) { total, word in
            total + word.filter { markers.contains($0) }.count + (vocabulary.contains(String(word)) ? 1 : 0)
        }
    }

    private static let ukrainianWords: Set<String> = [
        "що", "це", "як", "та", "але", "чи", "є", "буде", "треба", "дуже", "також", "можна",
        "щоб", "коли", "тому", "вже", "ще", "під", "від", "хто", "мене", "тобі", "дякую",
        "ласка", "або", "цей", "ця", "ці",
    ]

    private static let russianWords: Set<String> = [
        "что", "это", "как", "но", "или", "есть", "нужно", "очень", "также", "можно", "чтобы",
        "когда", "поэтому", "ещё", "под", "от", "кто", "меня", "тебе", "спасибо", "пожалуйста",
        "будет", "этот", "эта", "эти", "если", "здесь",
    ]

    private static let englishWords: Set<String> = [
        "the", "and", "is", "are", "was", "were", "we", "you", "to", "for", "that", "with",
        "this", "from", "have", "has", "it", "on", "at", "be", "not", "but", "or", "as", "by",
        "i", "our", "your", "they", "he", "she", "will", "can", "should", "would", "about", "into",
    ]
}
