// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct KnownBrowserExtension: Equatable, Sendable {
    public static let chromiumCanonicalStoragePaths = [
        "Local Extension Settings/<extension_id>/",
        "IndexedDB/chrome-extension_<extension_id>_*/",
        "Sync Extension Settings/<extension_id>/",
        "Extensions/<extension_id>/",
        "databases/chrome-extension_<extension_id>_*/"
    ]

    public let friendlyName: String
    public let extensionIDs: [String]
    public let publisherID: String?
    public let canonicalPaths: [String]
    public let notes: String?

    public init(
        friendlyName: String,
        extensionIDs: [String],
        publisherID: String? = nil,
        canonicalPaths: [String] = KnownBrowserExtension.chromiumCanonicalStoragePaths,
        notes: String? = nil
    ) {
        self.friendlyName = friendlyName
        self.extensionIDs = extensionIDs.map { $0.lowercased() }
        self.publisherID = publisherID
        self.canonicalPaths = canonicalPaths
        self.notes = notes
    }
}

public enum KnownExtensions {
    public static let chromiumExtensionIDPattern = #"^[a-p]{32}$"#

    public static let all: [KnownBrowserExtension] = [
        KnownBrowserExtension(friendlyName: "MetaMask", extensionIDs: ["nkbihfbeogaeaoehlefnkodbefgpgknn"]),
        KnownBrowserExtension(friendlyName: "MetaMask Beta", extensionIDs: ["pbpjkcldjiffchgbbndmhojiacbgflha"]),
        KnownBrowserExtension(friendlyName: "Phantom", extensionIDs: ["bfnaelmomeimhlpmgjnjophhpkkoljpa"]),
        KnownBrowserExtension(friendlyName: "Coinbase Wallet", extensionIDs: ["hnfanknocfeofbddgcijnmhnfnkdnaad"]),
        KnownBrowserExtension(friendlyName: "Rabby", extensionIDs: ["acmacodkjbdgmoleebolmdjonilkdbch"]),
        KnownBrowserExtension(friendlyName: "Rainbow", extensionIDs: ["opfgelmcmbiajamepnmloijbpoleiama"]),
        KnownBrowserExtension(friendlyName: "Backpack", extensionIDs: ["aflkmfhebedbjioipglgcbcmnbpgliof"]),
        KnownBrowserExtension(friendlyName: "Solflare", extensionIDs: ["bhhhlbepdkbapadjdnnojkbgioiodbic"]),
        KnownBrowserExtension(friendlyName: "Trust Wallet", extensionIDs: ["egjidjbpglichdcondbcbdnbeeppgdph"]),
        KnownBrowserExtension(friendlyName: "OKX Wallet", extensionIDs: ["mcohilncbfahbmgdjkbpemcciiolgcge"]),
        KnownBrowserExtension(friendlyName: "Frame", extensionIDs: ["ldcoohedfbjoobcadoglnnmmfbdlmmhf"]),
        KnownBrowserExtension(
            friendlyName: "Brave Wallet",
            extensionIDs: [],
            notes: "Built into Brave, not a Chrome Web Store extension. Browser profile storage still matters."
        ),
        KnownBrowserExtension(friendlyName: "Keplr", extensionIDs: ["dmkamcknogkgcdfhhbddcghachkejeap"]),
        KnownBrowserExtension(friendlyName: "MyTonWallet", extensionIDs: ["fldfpgipfncgndfolcbkdeeknbbbnhcc"]),
        KnownBrowserExtension(friendlyName: "Taho", extensionIDs: ["eajafomhmkipbjmfmhebemolkcicgfmd"], notes: "Formerly Tally Ho / Tally Cash."),
        KnownBrowserExtension(friendlyName: "Argent X", extensionIDs: ["dlcobpjiigpikoobohmabehhmhfoodbb"]),
        KnownBrowserExtension(friendlyName: "Petra", extensionIDs: ["ejjladinnckdgjemekebdpeokbikhfci"]),
        KnownBrowserExtension(friendlyName: "Suiet", extensionIDs: ["khpkpbbcccdmmclmpigdgddabeilkdpd"]),
        KnownBrowserExtension(friendlyName: "Slush (Sui Wallet)", extensionIDs: ["opcgpfmipidbgpenhmajoajpbobppdil"]),
        KnownBrowserExtension(friendlyName: "Martian", extensionIDs: ["efbglgofoippbgcjepnhiblaibcnclgk"]),
        KnownBrowserExtension(friendlyName: "Ctrl Wallet", extensionIDs: ["hmeobnfnfcmdkdcmlblgagmfpfboieaf"], notes: "Formerly XDEFI Wallet."),
        KnownBrowserExtension(friendlyName: "Talisman Wallet", extensionIDs: ["fijngjgcjhjmmpcmkeiomlglpeiijkld"]),
        KnownBrowserExtension(friendlyName: "Polkadot.js Extension", extensionIDs: ["mopnmbcafieddcagagdcbnhejhlodfdd"]),
        KnownBrowserExtension(friendlyName: "Compass Wallet", extensionIDs: ["anokgmphncpekkhclmingpimjmcooifb"]),
        KnownBrowserExtension(friendlyName: "Leap Wallet", extensionIDs: ["fcfcfllfndlomdhbehjjcoimbgofdncg"]),
        KnownBrowserExtension(
            friendlyName: "Capsule",
            extensionIDs: [],
            notes: "No current public Chromium extension ID verified during the v0.1 registry audit."
        ),
        KnownBrowserExtension(
            friendlyName: "Ledger Live",
            extensionIDs: [],
            notes: "Desktop app; retained here as crypto-adjacent coverage metadata."
        ),
        KnownBrowserExtension(
            friendlyName: "Trezor Suite",
            extensionIDs: [],
            notes: "Desktop/web app; retained here as crypto-adjacent coverage metadata."
        ),
        KnownBrowserExtension(
            friendlyName: "1Password",
            extensionIDs: ["aeblfdkhhhdcdjpifhhbdiojplfjncoa", "dppgmdbiimibapkepcbdbmkaabgiofem"],
            notes: "1Password has shipped multiple Chromium extension IDs."
        ),
        KnownBrowserExtension(friendlyName: "Bitwarden", extensionIDs: ["nngceckbapebfimnlniiiahkandclblb"]),
        KnownBrowserExtension(friendlyName: "Dashlane", extensionIDs: ["fdjamakpfbbddfjaooikfcpapjohcfmg"]),
        KnownBrowserExtension(friendlyName: "LastPass", extensionIDs: ["hdokiejnpimakedhajhdlcegeplioahd"]),
        KnownBrowserExtension(friendlyName: "KeePassXC-Browser", extensionIDs: ["oboonakemofpalcgghocfoadofidjkkk"]),
        KnownBrowserExtension(friendlyName: "NordPass", extensionIDs: ["eiaeiblijfjekdanodkjadfinkhbfgcd"]),
        KnownBrowserExtension(friendlyName: "Enpass", extensionIDs: ["kmcfomidfpdkfieipokbalgegidffkal"])
    ]

    public static func lookup(_ idOrFriendlyName: String) -> KnownBrowserExtension? {
        let normalized = idOrFriendlyName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { entry in
            entry.friendlyName.lowercased() == normalized || entry.extensionIDs.contains(normalized)
        }
    }

    public static func displayName(for extensionID: String) -> String? {
        lookup(extensionID)?.friendlyName
    }

    public static func isValidChromiumExtensionID(_ value: String) -> Bool {
        value.range(of: chromiumExtensionIDPattern, options: .regularExpression) != nil
    }
}
