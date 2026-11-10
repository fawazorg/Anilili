package com.anilili.data.update

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Verifies the Nostr fallback against a real, live-signed manifest event.
 *
 * The event below was captured from the relays on 2026-11-10 — the actual 0.1.84 release
 * manifest, with its real BIP-340 signature. It exercises the whole chain the app runs:
 * NIP-01 id re-serialization, the d-tag check, and the secp256k1 Schnorr verification.
 *
 * This is the test that would have caught the release being silently broken: R8 had shrunk the
 * secp256k1 JNI backend away, `Secp256k1.verifySchnorr` threw ExceptionInInitializerError, and
 * `runCatching { ... }.getOrDefault(false)` turned that into "signature invalid" — so every
 * release build rejected every manifest and the channel was inert.
 */
class NostrManifestVerificationTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val liveEventJson = """{"content":"{\"version\":\"0.1.84\",\"changelog\":\"## 🔗 Simkl\\n- **Simkl is here.** Connect it in **Settings ▸ Accounts**.\\n- Episodes you finish and changes to your list **go to Simkl automatically**.\\n- Works **alongside AniList or MyAnimeList**, or on its own.\\n- Simkl **never changes your library** or your signed-in account.\\n## 🖥️ Servers\\n- **kiwi, bee, bun and hop are back.** A change on Miruro's side stopped every episode list from loading, so picks quietly fell back to other servers.\\n- **AnimeHeaven** no longer plays a short **\\\"watch on our site\\\" clip** instead of the episode.\\n## 📺 Player & TV\\n- **Skip Intro and Skip Outro take one press of OK** on TV: the skip is focused as soon as it appears, instead of Up, Up, Up, then OK.\\n- Opening the controls while a skip is offered lands **on the skip**, not on Pause.\\n- Rows on TV **Home, Search, My List and Schedule stay centred** as you move up and down, no longer half under the top bar.\\n- **Down from the notifications bar** on TV reaches the grid again after you come back from a title.\\n- **Discord sign-in on TV** now works through the in-app browser.\\n## ✨ Also New\\n- **Series logos on the Home spotlight**, on phone and TV, like on the title page.\\n## 🔁 Build 96 · ▶️ Player\\n- **Sleep timer** in the player's settings: pause after **15, 30 or 45 minutes, 1 hour**, or **at the end of the episode**. The sound fades out first.\\n- **Filler episodes** carry a **FILLER** tag with **Skip to Episode N**, and **Settings ▸ Player ▸ Skip filler episodes** passes over them on Next and auto-play.\\n- The **screen can sleep again when you pause**: it only stays awake while an episode plays.\\n- On TV, **Down opens the controls on \\\"+85s\\\"** when the fixed skip is on.\\n- Fixed the **internal player crashing on start** on some Android 15 ROMs (crDroid).\\n## 🔁 Build 96 · 💬 Subtitles\\n- **Dubs show their signs and dialogue together** when the server has both tracks (ReAnime, ani.pm). Turn it off with **Show signs too** in the captions panel.\\n- **Subtitle delay and text size** now sit at the top of the captions panel, with bigger − and + buttons.\\n- Stray lines like **\\\"m 0 0 l 200 0…\\\"** no longer show up in the middle of signs.\\n## 🔁 Build 96 · 📋 Lists & Tracking\\n- **Score a title out of 10** from its list menu; it goes to AniList or MyAnimeList.\\n- **Set the episodes-watched count by hand**, to fix a count that ran ahead.\\n- **Rewatches are recorded** on AniList and MyAnimeList: the count starts again from 0, finishing adds one to your rewatch count, and the original dates are kept.\\n- **No account? Mark titles watched** on this device with the eye. Finishing a series marks it too, and the marks go to your account as Completed when you sign in.\\n- A series **finished from downloads** now leaves Continue Watching.\\n## 🔁 Build 96 · 📺 TV\\n- **Overscan** in **Settings ▸ Appearance** pulls the whole app in from the edges, for TV boxes that cut part of the picture off.\\n- **Forgot your profile PIN?** The PIN screen has a **Forgot PIN?** button. Ask in Discord for the reset code.\\n- The **PIN pad now sits beside its header**, so every button fits on a TV screen.\\n- **Down on Home glides to the next row** instead of stalling halfway.\\n- The **episode line on Continue Watching** is no longer cut in half under a two-line title.\\n## 🔁 Build 96 · ✨ Also New\\n- **The dice can deal from your own lists**: Plan to watch, Watching, Completed or any custom list.\\n- **Schedule** on phones has a **day stepper** at the bottom, so the next day is one tap away without scrolling back up.\\n- **Discord status** shows the series name, and the episode as **\\\"ep: 10/200 - Title\\\"**.\\n- The status card on titles that are **not out yet** fits and sits centred.\",\"apkUrl\":\"https://github.com/nshllagi99-hue/release-store/releases/latest/download/Anilili.apk\",\"sizeBytes\":20981013,\"versionCode\":96,\"variants\":{\"mobile\":{\"url\":\"https://github.com/nshllagi99-hue/release-store/releases/latest/download/Anilili.apk\",\"sizeBytes\":20981013,\"mirrors\":[\"https://huggingface.co/pommieye/kitsune-7b/resolve/main/latest/Anilili.apk\"]},\"tv\":{\"url\":\"https://github.com/nshllagi99-hue/release-store/releases/latest/download/Anilili_tv.apk\",\"sizeBytes\":17649850,\"mirrors\":[\"https://huggingface.co/pommieye/kitsune-7b/resolve/main/latest/Anilili_tv.apk\"]}}}","created_at":1792262266,"id":"5b04df2c89ec4819063129df6397e40fcd83d7781628e4add9c781b3153e0047","kind":30078,"pubkey":"f1abd1ac685aed1f5145271283cd9418bf13aa92ed26399df191ae0c08b22207","sig":"dc74aca33607e3c6e4953650b893cfed84cae7b098ddbaefef43217caf21c293800203c20047e6c76ac612660690f162091fc48d765ef5af21e97ddaf2564b38","tags":[["d","anilili-update"]]}"""

    private fun event() = json.parseToJsonElement(liveEventJson).jsonObject.toNostrEvent()

    @Test
    fun `the published manifest event passes full NIP-01 verification`() {
        val event = event()
        assertEquals(NostrUpdateSource.MANIFEST_PUBKEY_HEX, event.pubkey)
        assertEquals(NostrUpdateSource.MANIFEST_KIND, event.kind)
        // Re-serializing the event exactly as NIP-01 specifies must reproduce its id.
        assertEquals(event.id, event.computeEventIdHex())
        // ...and the Schnorr signature must check out against the project key.
        assertTrue("live manifest must verify", event.isValidManifest())
    }

    @Test
    fun `the manifest parses into an installable update`() {
        val info = event().parseManifest(json)
        assertEquals("0.1.84", info.version)
        assertTrue("apk must be fetched over TLS", info.apkUrl.startsWith("https://"))
        assertTrue("size should be populated", info.sizeBytes > 0)
    }

    /** Manifests published before the flavor split have no variants; a TV must still update. */
    @Test
    fun `a legacy manifest still gives a TV something to install`() {
        val legacy = event().copy(
            content = """
                {"version":"0.1.54","apkUrl":"https://example.test/Anilili.apk","sizeBytes":15022786}
            """.trimIndent(),
        )
        val info = legacy.parseManifest(json, isTv = true)
        assertEquals("0.1.54", info.version)
        assertTrue("falls back to the single apkUrl", info.apkUrl.endsWith("Anilili.apk"))
    }

    @Test
    fun `each form factor takes its own variant when the manifest offers them`() {
        val withVariants = event().copy(
            content = """
                {"version":"0.1.56","apkUrl":"https://example.test/Anilili.apk","sizeBytes":11,
                 "variants":{
                   "mobile":{"url":"https://example.test/Anilili.apk","sizeBytes":11},
                   "tv":{"url":"https://example.test/Anilili_tv.apk","sizeBytes":22}}}
            """.trimIndent(),
        )
        val tv = withVariants.parseManifest(json, isTv = true)
        assertEquals("https://example.test/Anilili_tv.apk", tv.apkUrl)
        assertEquals(22L, tv.sizeBytes)

        val phone = withVariants.parseManifest(json, isTv = false)
        assertEquals("https://example.test/Anilili.apk", phone.apkUrl)
        assertEquals(11L, phone.sizeBytes)
    }

    @Test
    fun `the build number is read when published and absent otherwise`() {
        // The live 0.1.84 manifest carries its build number; a manifest published before the
        // field existed must still parse, with no build to compare against.
        assertEquals(96, event().parseManifest(json).build)
        val withoutBuild = event().copy(
            content = """
                {"version":"0.1.54","apkUrl":"https://example.test/Anilili.apk","sizeBytes":1}
            """.trimIndent(),
        )
        assertEquals(null, withoutBuild.parseManifest(json).build)
        val withBuild = event().copy(
            content = """
                {"version":"0.1.80","versionCode":82,"apkUrl":"https://example.test/Anilili.apk",
                 "variants":{"tv":{"url":"https://example.test/Anilili_tv.apk","versionCode":83}}}
            """.trimIndent(),
        )
        assertEquals(82, withBuild.parseManifest(json, isTv = false).build)
        // A variant's own number wins, like its URL and size do.
        assertEquals(83, withBuild.parseManifest(json, isTv = true).build)
    }

    @Test
    fun `a manifest with only a mobile variant does not strand a TV`() {
        val mobileOnly = event().copy(
            content = """
                {"version":"0.1.56","apkUrl":"https://example.test/Anilili.apk",
                 "variants":{"mobile":{"url":"https://example.test/Anilili.apk"}}}
            """.trimIndent(),
        )
        assertEquals(
            "https://example.test/Anilili.apk",
            mobileOnly.parseManifest(json, isTv = true).apkUrl,
        )
    }

    @Test
    fun `a tampered manifest is rejected`() {
        // Same signature, different content: the id no longer matches, so it must not be trusted.
        val forged = event().copy(content = event().content.replace("0.1.84", "9.9.9"))
        assertFalse("content tampering must fail verification", forged.isValidManifest())
    }

    @Test
    fun `an event from another key is rejected`() {
        val impostor = event().copy(pubkey = "0".repeat(64))
        assertFalse("only the project key is trusted", impostor.isValidManifest())
    }
}
