import Foundation

/// Parrot's Product Hunt launch: a Home card for the one day it's live,
/// closed for good with one click. The dates ship in the app, so nothing is
/// fetched. Delete this and `LaunchDayCard` once the day has passed.
enum LaunchDay {
    static let url = URL(string: "https://www.producthunt.com/products/parrot-10?launch=parrot-5f95a2f0-bb9d-4992-bbb5-8c60031032dc")!

    /// Product Hunt days run midnight to midnight Pacific, and launches go
    /// live at 12:01am: 17 Oct 2026 07:01 UTC to 18 Oct 2026 07:00 UTC.
    static let start = Date(timeIntervalSince1970: 1_792_220_460)
    static let end = Date(timeIntervalSince1970: 1_792_306_800)

    /// Never ask for upvotes: Product Hunt buries launches that do.
    static let headline = "Parrot is live on Product Hunt today"
    static let subtitle = "If Parrot has helped on your calls, come say hi and tell people what you think. It means a lot to a one-person project."
    static let openTitle = "Open Product Hunt"

    /// True once the card was closed or its button used.
    static let closedKey = "productHuntLaunchCardClosed"

    /// Only while the launch is live, and never to someone still in the welcome tour.
    static func shouldShowCard(now: Date, closed: Bool, onboarded: Bool) -> Bool {
        onboarded && !closed && now >= start && now < end
    }

    /// When the card next appears or goes, so an open Home window can wake
    /// then. Nil once the day is over.
    static func nextChange(after now: Date) -> Date? {
        if now < start { return start }
        if now < end { return end }
        return nil
    }
}
