// SPDX-License-Identifier: AGPL-3.0-only
import Testing
@testable import SanctuaryCore

struct KnownExtensionsTests {
    @Test func curatedListContainsSpecEntries() {
        #expect(KnownExtensions.all.count == 35)
        let names = Set(KnownExtensions.all.map(\.friendlyName))
        for name in [
            "MetaMask", "MetaMask Beta", "Phantom", "Coinbase Wallet", "Rabby",
            "Rainbow", "Backpack", "Solflare", "Trust Wallet", "OKX Wallet",
            "Frame", "Brave Wallet", "Keplr", "MyTonWallet", "Taho", "Argent X",
            "Petra", "Suiet", "Slush (Sui Wallet)", "Martian", "Ctrl Wallet",
            "Talisman Wallet", "Polkadot.js Extension", "Compass Wallet",
            "Leap Wallet", "Capsule", "Ledger Live", "Trezor Suite", "1Password",
            "Bitwarden", "Dashlane", "LastPass", "KeePassXC-Browser", "NordPass",
            "Enpass"
        ] {
            #expect(names.contains(name))
        }
    }

    @Test func allKnownIDsUseChromiumExtensionIDFormat() {
        for id in KnownExtensions.all.flatMap(\.extensionIDs) {
            #expect(KnownExtensions.isValidChromiumExtensionID(id))
        }
    }

    @Test func friendlyNameLookupIsCaseInsensitive() throws {
        let extensionInfo = try #require(KnownExtensions.lookup("mEtAmAsK"))
        #expect(extensionInfo.extensionIDs == ["nkbihfbeogaeaoehlefnkodbefgpgknn"])
    }

    @Test func idLookupReturnsFriendlyName() throws {
        let extensionInfo = try #require(KnownExtensions.lookup("nngceckbapebfimnlniiiahkandclblb"))
        #expect(extensionInfo.friendlyName == "Bitwarden")
    }

    @Test func onePasswordCarriesBothKnownIDs() throws {
        let extensionInfo = try #require(KnownExtensions.lookup("1password"))
        #expect(extensionInfo.extensionIDs.contains("aeblfdkhhhdcdjpifhhbdiojplfjncoa"))
        #expect(extensionInfo.extensionIDs.contains("dppgmdbiimibapkepcbdbmkaabgiofem"))
    }

    @Test func entriesCarryCanonicalChromiumStoragePaths() throws {
        let extensionInfo = try #require(KnownExtensions.lookup("keplr"))
        #expect(extensionInfo.canonicalPaths == KnownBrowserExtension.chromiumCanonicalStoragePaths)
        #expect(extensionInfo.canonicalPaths.contains("Local Extension Settings/<extension_id>/"))
    }

    @Test func builtInOrDesktopOnlyEntriesDoNotInventExtensionIDs() throws {
        #expect(try #require(KnownExtensions.lookup("Brave Wallet")).extensionIDs.isEmpty)
        #expect(try #require(KnownExtensions.lookup("Ledger Live")).extensionIDs.isEmpty)
        #expect(try #require(KnownExtensions.lookup("Trezor Suite")).extensionIDs.isEmpty)
    }
}
