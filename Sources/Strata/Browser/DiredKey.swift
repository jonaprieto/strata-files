/// What a plain letter does with Dired keys on, as in Emacs. Any other letter does nothing.
enum DiredKey {
    case down
    case up
    case left
    case right
    case filter
    case run(StrataCommand)

    init?(_ text: String) {
        switch text {
        case "n", "j": self = .down
        case "p", "k": self = .up
        case "h": self = .left
        case "l": self = .right
        case "/": self = .filter
        case "f": self = .run(.openSelection)
        case "^": self = .run(.goToEnclosingFolder)
        case "g": self = .run(.reloadFolder)
        case "R": self = .run(.renameSelection)
        case "+": self = .run(.newFolder)
        case "C": self = .run(.copyToOtherPane)
        case "D": self = .run(.moveToTrash)
        case "w": self = .run(.copyName)
        case "W": self = .run(.copyRelativePath)
        default: return nil
        }
    }
}
