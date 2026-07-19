import Foundation

/// Sample thoughts in the app's voice. Stands in for a real store until persistence lands.
enum MockThoughts {
    static let all: [Thought] = {
        let now = Date()
        let hour: TimeInterval = 60 * 60
        let day: TimeInterval = 24 * hour

        return [
            Thought(
                title: "Morning drive - thoughts",
                paragraphs: [
                    "Remember to call the supplier about the Shea butter order before noon. "
                        + "Then draft the launch email.",
                    "Ask whether the new batch ships in the kraft boxes or the old white "
                        + "ones. The kraft ones photograph better for the launch shots."
                ],
                createdAt: now.addingTimeInterval(-2 * hour)
            ),
            Thought(
                title: "Launch email - rough cut",
                paragraphs: [
                    "Open with the story of why the balm exists, not the ingredient list. "
                        + "People buy the reason before the recipe.",
                    "Keep it to three short paragraphs. One promise, one proof, one ask.",
                    "Sign off warm. No hard sell. Let the product carry the close."
                ],
                createdAt: now.addingTimeInterval(-6 * hour)
            ),
            Thought(
                title: "Walk - product ideas",
                paragraphs: [
                    "A travel tin, half the size, for the carry-on crowd. Same balm, smaller "
                        + "commitment. Good gateway product.",
                    "Try a lavender and cedar scent for the winter run. Test it on the "
                        + "regulars first before committing to a batch."
                ],
                createdAt: now.addingTimeInterval(-1 * day)
            ),
            Thought(
                title: "Kitchen - errands and reminders",
                paragraphs: [
                    "Move the standing order to Tuesdays so the jars arrive before the "
                        + "weekend market, not after it.",
                    "Book the photographer for the second week of next month. Ask about "
                        + "the natural-light slot in the morning."
                ],
                createdAt: now.addingTimeInterval(-2 * day)
            )
        ]
    }()
}
