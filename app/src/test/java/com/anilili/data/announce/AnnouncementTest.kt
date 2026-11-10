package com.anilili.data.announce

import com.anilili.data.update.NostrUpdateSource
import com.anilili.data.update.toNostrEvent
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The broadcast channel's rules, all of them decided off-device.
 *
 * This channel can put a notification on every install in the world, so the interesting tests are
 * the ones about what it *refuses*: an event signed for the other channel, a link that is not a web
 * page, a message aimed at versions this build is not.
 */
class AnnouncementTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /**
     * The real 0.1.84 update manifest, live-signed, lifted from `NostrManifestVerificationTest`.
     * Its signature is genuine — the only thing wrong with it here is its d-tag.
     */
    private val liveUpdateEventJson = """{"content":"{\"version\":\"0.1.84\",\"changelog\":\"## 🔗 Simkl\\n- **Simkl is here.** Connect it in **Settings ▸ Accounts**.\\n- Episodes you finish and changes to your list **go to Simkl automatically**.\\n- Works **alongside AniList or MyAnimeList**, or on its own.\\n- Simkl **never changes your library** or your signed-in account.\\n## 🖥️ Servers\\n- **kiwi, bee, bun and hop are back.** A change on Miruro's side stopped every episode list from loading, so picks quietly fell back to other servers.\\n- **AnimeHeaven** no longer plays a short **\\\"watch on our site\\\" clip** instead of the episode.\\n## 📺 Player & TV\\n- **Skip Intro and Skip Outro take one press of OK** on TV: the skip is focused as soon as it appears, instead of Up, Up, Up, then OK.\\n- Opening the controls while a skip is offered lands **on the skip**, not on Pause.\\n- Rows on TV **Home, Search, My List and Schedule stay centred** as you move up and down, no longer half under the top bar.\\n- **Down from the notifications bar** on TV reaches the grid again after you come back from a title.\\n- **Discord sign-in on TV** now works through the in-app browser.\\n## ✨ Also New\\n- **Series logos on the Home spotlight**, on phone and TV, like on the title page.\\n## 🔁 Build 96 · ▶️ Player\\n- **Sleep timer** in the player's settings: pause after **15, 30 or 45 minutes, 1 hour**, or **at the end of the episode**. The sound fades out first.\\n- **Filler episodes** carry a **FILLER** tag with **Skip to Episode N**, and **Settings ▸ Player ▸ Skip filler episodes** passes over them on Next and auto-play.\\n- The **screen can sleep again when you pause**: it only stays awake while an episode plays.\\n- On TV, **Down opens the controls on \\\"+85s\\\"** when the fixed skip is on.\\n- Fixed the **internal player crashing on start** on some Android 15 ROMs (crDroid).\\n## 🔁 Build 96 · 💬 Subtitles\\n- **Dubs show their signs and dialogue together** when the server has both tracks (ReAnime, ani.pm). Turn it off with **Show signs too** in the captions panel.\\n- **Subtitle delay and text size** now sit at the top of the captions panel, with bigger − and + buttons.\\n- Stray lines like **\\\"m 0 0 l 200 0…\\\"** no longer show up in the middle of signs.\\n## 🔁 Build 96 · 📋 Lists & Tracking\\n- **Score a title out of 10** from its list menu; it goes to AniList or MyAnimeList.\\n- **Set the episodes-watched count by hand**, to fix a count that ran ahead.\\n- **Rewatches are recorded** on AniList and MyAnimeList: the count starts again from 0, finishing adds one to your rewatch count, and the original dates are kept.\\n- **No account? Mark titles watched** on this device with the eye. Finishing a series marks it too, and the marks go to your account as Completed when you sign in.\\n- A series **finished from downloads** now leaves Continue Watching.\\n## 🔁 Build 96 · 📺 TV\\n- **Overscan** in **Settings ▸ Appearance** pulls the whole app in from the edges, for TV boxes that cut part of the picture off.\\n- **Forgot your profile PIN?** The PIN screen has a **Forgot PIN?** button. Ask in Discord for the reset code.\\n- The **PIN pad now sits beside its header**, so every button fits on a TV screen.\\n- **Down on Home glides to the next row** instead of stalling halfway.\\n- The **episode line on Continue Watching** is no longer cut in half under a two-line title.\\n## 🔁 Build 96 · ✨ Also New\\n- **The dice can deal from your own lists**: Plan to watch, Watching, Completed or any custom list.\\n- **Schedule** on phones has a **day stepper** at the bottom, so the next day is one tap away without scrolling back up.\\n- **Discord status** shows the series name, and the episode as **\\\"ep: 10/200 - Title\\\"**.\\n- The status card on titles that are **not out yet** fits and sits centred.\",\"apkUrl\":\"https://github.com/nshllagi99-hue/release-store/releases/latest/download/Anilili.apk\",\"sizeBytes\":20981013,\"versionCode\":96,\"variants\":{\"mobile\":{\"url\":\"https://github.com/nshllagi99-hue/release-store/releases/latest/download/Anilili.apk\",\"sizeBytes\":20981013,\"mirrors\":[\"https://huggingface.co/pommieye/kitsune-7b/resolve/main/latest/Anilili.apk\"]},\"tv\":{\"url\":\"https://github.com/nshllagi99-hue/release-store/releases/latest/download/Anilili_tv.apk\",\"sizeBytes\":17649850,\"mirrors\":[\"https://huggingface.co/pommieye/kitsune-7b/resolve/main/latest/Anilili_tv.apk\"]}}}","created_at":1792262266,"id":"5b04df2c89ec4819063129df6397e40fcd83d7781628e4add9c781b3153e0047","kind":30078,"pubkey":"f1abd1ac685aed1f5145271283cd9418bf13aa92ed26399df191ae0c08b22207","sig":"dc74aca33607e3c6e4953650b893cfed84cae7b098ddbaefef43217caf21c293800203c20047e6c76ac612660690f162091fc48d765ef5af21e97ddaf2564b38","tags":[["d","anilili-update"]]}"""

    /**
     * The d-tag is the whole separation between the two channels, since they share a key and a
     * kind. If this ever passed, a signed update manifest would be replayable as an announcement.
     */
    @Test
    fun `a genuinely signed update manifest is not an announcement`() {
        val event = json.parseToJsonElement(liveUpdateEventJson).jsonObject.toNostrEvent()
        assertTrue("control: this event really is validly signed", event.isValidManifest())
        assertFalse(
            "the update d-tag must not satisfy the announcement channel",
            event.isValidSignedBy(
                NostrUpdateSource.MANIFEST_PUBKEY_HEX,
                NostrUpdateSource.MANIFEST_KIND,
                AnnouncementSource.D_TAG,
            ),
        )
    }

    /**
     * A real announcement, signed by the project key with `scripts/nostr_update.py announce`.
     *
     * The publisher and the app are two independent implementations of NIP-01 — one in Python
     * against coincurve, one in Kotlin against secp256k1 — and nothing but a test like this notices
     * when they stop agreeing. That is not hypothetical for this channel: the update manifest it
     * shares a key with spent an entire release silently rejecting every event, because the
     * verifier could not run at all and a `runCatching` turned that into "not genuine".
     */
    private val liveAnnouncementEventJson = """{"id":"1a3e007da72179bb5cae37be96c334c06b58e1c9670541a9bf528a823e705d65","pubkey":"f1abd1ac685aed1f5145271283cd9418bf13aa92ed26399df191ae0c08b22207","created_at":1788559744,"kind":30078,"tags":[["d","anilili-announcement"]],"content":"{\"id\":\"test-signing-loop\",\"title\":\"Sources are down\",\"message\":\"Not your device - the provider is having an outage.\",\"url\":\"https://example.test/status\",\"urlLabel\":\"Status page\",\"severity\":\"emergency\",\"maxVersion\":\"0.1.99\"}","sig":"701f8435a36433c0543abd0c9dc1889c954b91b3691cee7f7d2e5493f6c37c3264ea29714a0ad71b4d36b32ce4bf4b1102a4c18f08fa177638beb8cbf8b694d9"}"""

    @Test
    fun `an event the publish script signed passes the app's verification and parses`() {
        val event = json.parseToJsonElement(liveAnnouncementEventJson).jsonObject.toNostrEvent()
        assertEquals("NIP-01 id must re-serialize identically", event.id, event.computeEventIdHex())
        assertTrue(
            "the script and the app must agree on what a valid announcement is",
            event.isValidSignedBy(
                NostrUpdateSource.MANIFEST_PUBKEY_HEX,
                NostrUpdateSource.MANIFEST_KIND,
                AnnouncementSource.D_TAG,
            ),
        )
        val parsed = parseAnnouncement(json, event.content)
        assertEquals("test-signing-loop", parsed?.id)
        assertEquals("Sources are down", parsed?.title)
        assertTrue("--emergency must reach the loud channel", parsed?.urgent == true)
        assertEquals("example.test", parsed?.urlHost)
        assertTrue(announcementApplies(parsed!!, "0.1.76", nowSec = 1_788_600_000L))
    }

    /** The reverse direction of the same guard: it must not verify against the update channel. */
    @Test
    fun `a signed announcement is not an update manifest`() {
        val event = json.parseToJsonElement(liveAnnouncementEventJson).jsonObject.toNostrEvent()
        assertFalse(event.isValidManifest())
    }

    @Test
    fun `a full announcement parses`() {
        val parsed = parseAnnouncement(
            json,
            """{"id":"outage-2026-09","title":"Sources are down","message":"Not your device.",
               "url":"https://example.test/status","urlLabel":"Status page","severity":"emergency",
               "expiresAt":1790000000,"minVersion":"0.1.70","maxVersion":"0.1.76"}""",
        )
        assertEquals("outage-2026-09", parsed?.id)
        assertEquals("Sources are down", parsed?.title)
        assertTrue("emergency routes to the loud channel", parsed?.urgent == true)
        assertEquals("Status page", parsed?.urlLabel)
        assertEquals("example.test", parsed?.urlHost)
        assertEquals(1790000000L, parsed?.expiresAt)
    }

    @Test
    fun `an announcement without an id or a message is not shown`() {
        assertNull(parseAnnouncement(json, """{"title":"Hi","message":"No id here"}"""))
        assertNull(parseAnnouncement(json, """{"id":"x","title":"Hi"}"""))
        assertNull(parseAnnouncement(json, """{"id":"  ","message":"blank id"}"""))
        assertNull(parseAnnouncement(json, "not json at all"))
    }

    /** Absent severity is the quiet channel: an ordinary notice must not buzz like an emergency. */
    @Test
    fun `severity defaults to not urgent`() {
        val parsed = parseAnnouncement(json, """{"id":"a","message":"Just so you know"}""")
        assertFalse(parsed?.urgent == true)
        assertEquals("Anilili", parsed?.title)
    }

    /**
     * The link is the one part of a broadcast that reaches outside the app, so anything that is
     * not plainly a web page is dropped rather than passed to `Intent.parseUri`.
     */
    @Test
    fun `only https links survive`() {
        assertEquals("https://example.test/x", sanitizeAnnouncementUrl("https://example.test/x"))
        assertNull("http would be a downgrade in a signed message", sanitizeAnnouncementUrl("http://example.test"))
        assertNull("intent urls can address another app", sanitizeAnnouncementUrl("intent://scan#Intent;end"))
        assertNull(sanitizeAnnouncementUrl("javascript:alert(1)"))
        assertNull(sanitizeAnnouncementUrl("file:///sdcard/x.apk"))
        assertNull("a scheme with no host is not a page", sanitizeAnnouncementUrl("https:///nohost"))
        assertNull(sanitizeAnnouncementUrl(null))
        assertNull(sanitizeAnnouncementUrl("   "))
    }

    @Test
    fun `a link that failed sanitising leaves the announcement without one`() {
        val parsed = parseAnnouncement(json, """{"id":"a","message":"m","url":"intent://x#Intent;end"}""")
        assertEquals("a", parsed?.id)
        assertNull("the message still shows, just without a button", parsed?.url)
        assertNull(parsed?.urlHost)
    }

    @Test
    fun `an expired announcement is not shown`() {
        val announcement = Announcement(id = "a", title = "t", message = "m", expiresAt = 1_000L)
        assertFalse(announcementApplies(announcement, "0.1.76", nowSec = 1_001L))
        assertTrue(announcementApplies(announcement, "0.1.76", nowSec = 999L))
    }

    /** Zero is the "no expiry" sentinel, and must not read as "expired in 1970". */
    @Test
    fun `an announcement with no expiry never expires`() {
        val announcement = Announcement(id = "a", title = "t", message = "m", expiresAt = 0L)
        assertTrue(announcementApplies(announcement, "0.1.76", nowSec = 9_999_999_999L))
    }

    /** "0.1.76 is broken, stay on 0.1.75" must reach 0.1.76 and nobody else. */
    @Test
    fun `version bounds are inclusive on both ends`() {
        val announcement = Announcement(
            id = "bad-release",
            title = "t",
            message = "m",
            minVersion = "0.1.74",
            maxVersion = "0.1.76",
        )
        assertFalse(announcementApplies(announcement, "0.1.73", nowSec = 1L))
        assertTrue(announcementApplies(announcement, "0.1.74", nowSec = 1L))
        assertTrue(announcementApplies(announcement, "0.1.75", nowSec = 1L))
        assertTrue(announcementApplies(announcement, "0.1.76", nowSec = 1L))
        assertFalse(announcementApplies(announcement, "0.1.77", nowSec = 1L))
    }

    @Test
    fun `an unbounded announcement reaches every version`() {
        val announcement = Announcement(id = "a", title = "t", message = "m")
        assertTrue(announcementApplies(announcement, "0.0.1", nowSec = 1L))
        assertTrue(announcementApplies(announcement, "9.9.9", nowSec = 1L))
    }
}
