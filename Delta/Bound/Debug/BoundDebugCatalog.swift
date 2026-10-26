import Foundation

struct BoundDebugPoint: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let location: String
    let prerequisites: String
    let mechanics: String
    let format: String
    let purpose: String
    let nativeSteps: String
}

/// These stable catalog IDs are distinct from native trainer IDs. Certification
/// and prepared-party/level-cap details come from the exact fixture manifest.
enum BoundDebugCatalog {
    static let fixtureVersion = "multiplayer-isolation-v1"
    static let points: [BoundDebugPoint] = [
        .init(id: "01", title: "Pallet Town — Paired Start", location: "Outside Oak’s lab",
              prerequisites: "Native starter and setup completion.",
              mechanics: "Distinct trainer identities and starter teams; Infinite Repel enabled.", format: "Independent field play",
              purpose: "Pairing, movement, transitions, encounters, acquisitions, saving and reconnecting.",
              nativeSteps: "Walk independently, enter a building, or approach a nearby encounter."),
        .init(id: "02", title: "Brock", location: "Pewter Gym, before Brock",
              prerequisites: "Parcel delivery, Pokédex, early route progression, Brendan and Falkner; Brock undefeated.",
              mechanics: "First badge and native level-cap progression; rewards unclaimed.", format: "Native singles",
              purpose: "Local menus, rewards, badge progression and return to the gym.", nativeSteps: "Approach Brock and speak to him."),
        .init(id: "03", title: "Super Nerd Miguel", location: "Mt. Moon, outside Miguel’s trigger",
              prerequisites: "Early progression and valid Mt. Moon access; Miguel undefeated.",
              mechanics: "Early doubles with small, native parties and intact encounter scripts.", format: "Native doubles",
              purpose: "Party ownership, small-party selection and post-battle progression.", nativeSteps: "Approach the native encounter trigger."),
        .init(id: "04", title: "Ann & Brooks", location: "S.S. Anne, before Ann and Brooks",
              prerequisites: "Valid ship access and ticket progression; encounter still available.",
              mechanics: "Two opponents, native party selection and ship scripts.", format: "Two-opponent doubles",
              purpose: "Selection, cancellation and return without duplicate rewards.", nativeSteps: "Initiate the original encounter through its native interaction."),
        .init(id: "05", title: "Ariana & Archer — Silph Co.", location: "Silph Co., before the assisted encounter",
              prerequisites: "Required Silph progression through the encounter, with the target unbeaten.",
              mechanics: "Native Brendan assistance can be substituted by the joined human partner.", format: "Assisted doubles",
              purpose: "Human substitution, owned Pokémon and post-battle scripts.", nativeSteps: "Speak to or approach the native encounter trigger."),
        .init(id: "06", title: "Sabrina", location: "Saffron Gym, before Sabrina",
              prerequisites: "Valid Saffron and gym access; Sabrina undefeated and rewards unclaimed.",
              mechanics: "Native boss rules, EXP and gym completion.", format: "Native boss doubles",
              purpose: "Move selection, switching, EXP, rewards and completion.", nativeSteps: "Approach Sabrina and speak to her."),
        .init(id: "07", title: "Lola & Sheila", location: "Route 13, outside the native trigger",
              prerequisites: "Valid Route 13 progression; both opponents available.",
              mechanics: "Permanent sun and native field-to-battle transition.", format: "Native doubles",
              purpose: "Weather, ownership and field return.", nativeSteps: "Walk into the original encounter range or interact with the trainers."),
        .init(id: "08", title: "Tamer Ramiro", location: "Route 18, before Ramiro",
              prerequisites: "Valid Route 18 access; original encounter undefeated.",
              mechanics: "Permanent rain and weather-dependent native behavior.", format: "Native doubles",
              purpose: "Rain behavior, move selection and progression.", nativeSteps: "Approach Ramiro and initiate the original encounter."),
        .init(id: "09", title: "Ace Zac", location: "Cinnabar Gym, before Zac",
              prerequisites: "Valid Cinnabar Gym access; Zac undefeated.",
              mechanics: "Permanent sun and intact gym progression scripts.", format: "Native doubles",
              purpose: "Late-game parties, weather and gym continuity.", nativeSteps: "Approach Zac and initiate the native encounter."),
        .init(id: "10", title: "Archer → Ariana — Cerulean Cave", location: "Cerulean Cave, before Archer",
              prerequisites: "Required cave progression; neither target battle completed.",
              mechanics: "Consecutive native battles with party condition retained between them.", format: "Original format of each battle",
              purpose: "Sequence transitions, checkpoint timing and recovery.", nativeSteps: "Initiate Archer’s encounter and follow the original sequence into Ariana."),
        .init(id: "11", title: "Giovanni — Cerulean Cave", location: "Cerulean Cave, before Giovanni",
              prerequisites: "Earlier cave encounters completed; Giovanni’s encounter available.",
              mechanics: "Lance assistance, human substitution and native Mewtwo transformation after its first defeat.", format: "Assisted doubles",
              purpose: "Ownership, scripted transformation and continuation.", nativeSteps: "Approach Giovanni and follow the native encounter script."),
        .init(id: "12", title: "Lorelei — Rain", location: "Pokémon League, before Lorelei",
              prerequisites: "Valid League entry with the native Rain Team variant selected.",
              mechanics: "Rain team and native Elite Four progression.", format: "Native doubles",
              purpose: "Variant selection, rain and League progression.", nativeSteps: "Enter Lorelei’s room and speak to her."),
        .init(id: "13", title: "Lorelei — Snow", location: "Pokémon League, before Lorelei",
              prerequisites: "Valid League entry with the native Snow Team variant selected.",
              mechanics: "Snow team and native Elite Four progression.", format: "Native doubles",
              purpose: "Alternate team, weather and League progression.", nativeSteps: "Enter Lorelei’s room and speak to her."),
        .init(id: "14", title: "Champion — Rival", location: "Champion’s room, before the rival",
              prerequisites: "Preceding Elite Four encounters completed; rival variant matches each trainer’s starter choice.",
              mechanics: "Original rival team, Hall of Fame, credits and native save sequence.", format: "Native singles",
              purpose: "Victory, loss, Hall of Fame, saving and postgame continuation.", nativeSteps: "Approach the rival through the original room trigger."),
        .init(id: "15", title: "Pryce — Postgame", location: "Seafoam Islands’ secret room, outside Pryce’s trigger",
              prerequisites: "Postgame and secret-room access, including the required native key items.",
              mechanics: "Native initial frostbite and Kyurem’s scripted transformation.", format: "Native doubles",
              purpose: "Postgame conditions, transformation, rewards and return.", nativeSteps: "Approach Pryce from the nearby staging tile.")
    ]
}
