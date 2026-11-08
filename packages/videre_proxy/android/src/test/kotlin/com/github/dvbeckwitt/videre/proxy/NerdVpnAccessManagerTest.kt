package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

class NerdVpnAccessManagerTest {
    private val origin = "https://invidious.nerdvpn.de".toHttpUrl()
    private val account = GatewayContext("0247ed8b-e84e-5b9e-9ab6-aa534f64c031", origin)
    private val secondAccount = GatewayContext("0247ed8b-e84e-5b9e-9ab6-aa534f64c032", origin)
    private val video = "https://invidious.nerdvpn.de/api/v1/videos/fixture".toHttpUrl()
    private val originalKey = "nvpn_" + "A".repeat(32)
    private val replacementKey = "nvpn_" + "b".repeat(32)
    private val token = "fixture-account-token"
    private val initialTime = 1_800_000_000_000L

    @Test fun `credentials resolve only for exact approved HTTPS origin`() {
        val store = MemoryStore()
        val manager = manager(store)
        manager.setKey(account, originalKey)
        assertTrue(isNerdVpnOrigin(origin))
        assertEquals(originalKey, manager.resolve(account, video).apiKey)
        assertEquals(originalKey, manager.resolve(account, origin.resolve("/vi/fixture/default.jpg")!!).apiKey)
        for (address in listOf(
            "http://invidious.nerdvpn.de/api/v1/stats",
            "https://invidious.nerdvpn.de:8443/api/v1/stats",
            "https://invidious.nerdvpn.de.attacker.example/api/v1/stats",
            "https://www.invidious.nerdvpn.de/api/v1/stats",
            "https://user@invidious.nerdvpn.de/api/v1/stats",
            "https://cdn.example/segment.ts",
        )) {
            val url = address.toHttpUrl()
            assertFalse(address, isNerdVpnOrigin(url))
            assertNull(address, manager.resolve(account, url).apiKey)
        }
        assertThrows(IllegalArgumentException::class.java) {
            manager.setKey(account.copy(origin = "https://other.example".toHttpUrl()), originalKey)
        }
    }

    @Test fun `bootstrap endpoints remain available while API access is waiting`() {
        val store = MemoryStore()
        val manager = manager(store) { _, _ ->
            NerdVpnKeyResult(403, error = "not_yet_eligible", availableAt = initialTime + 60_000)
        }
        manager.authorize(account, token)
        assertEquals("waiting", manager.resolve(account, video).error)
        for (path in listOf("/api/v1/token", "/api/v1/auth/api_key")) {
            val resolved = manager.resolve(account, origin.resolve(path)!!)
            assertNull(resolved.apiKey)
            assertNull(resolved.error)
        }
        assertEquals("waiting", manager.resolve(account, origin.resolve("/api/v1/token/other")!!).error)
    }

    @Test fun `eligibility uses saved server time and requires a successful key fetch`() {
        val store = MemoryStore()
        var time = initialTime
        val availableAt = time + 123_000
        var requests = 0
        val fetch = { _: GatewayContext, _: String ->
            requests++
            if (requests == 1) NerdVpnKeyResult(403, error = "not_yet_eligible", availableAt = availableAt)
            else NerdVpnKeyResult(200, key = replacementKey)
        }
        val manager = NerdVpnAccessManager(store, fetch) { time }
        val waiting = manager.authorize(account, token)
        assertEquals("waiting", waiting["state"])
        assertEquals(nerdVpnTimestamp(availableAt), waiting["availableAt"])

        val restarted = NerdVpnAccessManager(store, fetch) { time }
        assertEquals("waiting", restarted.resolve(account, video).error)
        assertEquals(1, requests)
        time = availableAt
        assertEquals(replacementKey, restarted.resolve(account, video).apiKey)
        assertEquals(2, requests)
        assertEquals("ready", restarted.status(account)["state"])
    }

    @Test fun `reaching eligibility waits for a longer gateway cooldown before requesting a key`() {
        val store = MemoryStore()
        var time = initialTime
        var fetches = 0
        val manager = NerdVpnAccessManager(store, { _, _ ->
            fetches++
            if (fetches == 1) NerdVpnKeyResult(403, error = "not_yet_eligible", availableAt = initialTime + 10_000)
            else NerdVpnKeyResult(200, key = replacementKey)
        }) { time }
        manager.authorize(account, token)
        val pending = manager.resolve(account, video)
        manager.recover(account, "rate_limited", 429, 30, pending.apiKey,
            pending.revision, failedIntent = pending.intent)
        time = initialTime + 10_000
        assertEquals("waiting", manager.resolve(account, video).error)
        assertEquals(1, fetches)
        time = initialTime + 29_999
        assertEquals("waiting", manager.resolve(account, video).error)
        assertEquals(1, fetches)
        time = initialTime + 30_000
        assertEquals(replacementKey, manager.resolve(account, video).apiKey)
        assertEquals(2, fetches)
    }

    @Test fun `disabled and denied access stop automatic recovery until explicit check`() {
        for ((serverError, state) in listOf("access_disabled" to "disabled", "access_denied" to "denied")) {
            val store = MemoryStore()
            var requests = 0
            val manager = manager(store) { _, _ ->
                requests++
                if (requests == 1) NerdVpnKeyResult(403, error = serverError)
                else NerdVpnKeyResult(200, key = replacementKey)
            }
            manager.authorize(account, token)
            val blocked = manager.resolve(account, video)
            assertEquals(state, blocked.error)
            assertEquals(false, manager.recover(account, "invalid_credentials", 401, null,
                null, blocked.revision)["retryAllowed"])
            assertEquals(1, requests)
            assertEquals("ready", manager.check(account)["state"])
            assertEquals(replacementKey, manager.resolve(account, video).apiKey)
            assertEquals(2, requests)
        }
    }

    @Test fun `simultaneous key failures share recovery even when returned key is unchanged`() {
        val store = MemoryStore()
        store.write(account, NerdVpnRecord(token = token, key = originalKey, state = "ready",
            revision = 7, credentialIntent = 11))
        val fetches = AtomicInteger()
        val recovering = CountDownLatch(1)
        val release = CountDownLatch(1)
        val manager = manager(store) { _, _ ->
            fetches.incrementAndGet()
            recovering.countDown()
            assertTrue(release.await(5, TimeUnit.SECONDS))
            NerdVpnKeyResult(200, key = originalKey)
        }
        val executor = Executors.newFixedThreadPool(8)
        try {
            val failures = (1..8).map {
                executor.submit<Map<String, Any>> {
                    manager.recover(account, "invalid_credentials", 401, null, originalKey, 7,
                        failedIntent = 11)
                }
            }
            assertTrue(recovering.await(5, TimeUnit.SECONDS))
            release.countDown()
            failures.forEach { assertEquals(true, it.get(5, TimeUnit.SECONDS)["retryAllowed"]) }
            assertEquals(1, fetches.get())
            assertEquals(11L, store.read(account)?.credentialIntent)
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun `a failed retry stops recovery while retaining the account token`() {
        val store = MemoryStore()
        var fetches = 0
        val manager = manager(store) { _, _ ->
            fetches++
            NerdVpnKeyResult(200, key = originalKey)
        }
        manager.authorize(account, token)
        val first = manager.resolve(account, video)
        assertEquals(true, manager.recover(account, "invalid_credentials", 401, null,
            first.apiKey, first.revision)["retryAllowed"])
        val retried = manager.resolve(account, video)
        assertEquals(false, manager.recover(account, "invalid_credentials", 401, null,
            retried.apiKey, retried.revision, retry = false)["retryAllowed"])
        assertEquals("signInRequired", manager.resolve(account, video).error)
        assertEquals(token, store.read(account)?.token)
        assertEquals(2, fetches)
    }

    @Test fun `cooldown retains credentials across restart and honors Retry-After`() {
        for ((code, gatewayError) in listOf(429 to "rate_limited", 503 to "unavailable")) {
            val store = MemoryStore()
            store.write(account, NerdVpnRecord(token = token, key = originalKey, state = "ready", revision = 9))
            var time = initialTime
            val manager = NerdVpnAccessManager(store, { _, _ -> error("Cooldown must not retrieve a key") }) { time }
            val response = manager.recover(account, gatewayError, code, 17, originalKey, 9)
            assertEquals(nerdVpnTimestamp(time + 17_000), response["retryAt"])
            assertEquals(originalKey, store.read(account)?.key)
            assertEquals(token, store.read(account)?.token)
            val restarted = NerdVpnAccessManager(store, { _, _ -> error("A usable key is already stored") }) { time }
            time += 16_999
            assertEquals("unavailable", restarted.resolve(account, video).error)
            assertEquals("unavailable", restarted.check(account)["state"])
            time++
            assertEquals(originalKey, restarted.resolve(account, video).apiKey)
        }
    }

    @Test fun `ambiguous token rejection preserves login and pauses requests for sign-in`() {
        val responses = listOf(
            NerdVpnKeyResult(401, error = "Unrecognized upstream response"),
            NerdVpnKeyResult(403, error = "Some unexpected refusal"),
        )
        for (response in responses) {
            val store = MemoryStore()
            var fetches = 0
            val manager = manager(store) { _, _ -> fetches++; response }
            assertEquals("signInRequired", manager.authorize(account, token)["state"])
            assertEquals(token, store.read(account)?.token)
            assertNull(store.read(account)?.key)
            assertEquals("signInRequired", manager.resolve(account, video).error)
            manager.recover(account, "invalid_credentials", 401, null, null, store.read(account)!!.revision)
            assertEquals(1, fetches)
        }
    }

    @Test fun `malformed key response and transport failure preserve login during cooldown`() {
        val malformedStore = MemoryStore()
        val malformed = manager(malformedStore) { _, _ -> NerdVpnKeyResult(200, key = "malformed") }
        assertEquals("unavailable", malformed.authorize(account, token)["state"])
        assertEquals(token, malformedStore.read(account)?.token)
        assertNull(malformedStore.read(account)?.key)
        assertEquals("unavailable", malformed.resolve(account, video).error)

        val store = MemoryStore()
        val manager = manager(store) { _, _ -> throw IOException("Fixture connection failure") }
        assertEquals("unavailable", manager.authorize(account, token)["state"])
        assertEquals(token, store.read(account)?.token)
    }

    @Test fun `authentication intents reject callbacks superseded by logout or newer sign-in`() {
        for (supersededByClear in listOf(true, false)) {
            val store = MemoryStore()
            val manager = manager(store)
            manager.setKey(account, originalKey)
            val intent = manager.beginAuth(account)["intent"] as Long
            if (supersededByClear) manager.clear(account) else manager.beginAuth(account)
            val before = store.read(account)
            val result = manager.authorize(account, token, intent)
            assertEquals(true, result["superseded"])
            assertEquals(before, store.read(account))
            assertNull(store.read(account)?.token)
        }
    }

    @Test fun `media key recovery does not supersede a pending authentication intent`() {
        val store = MemoryStore()
        store.write(account, NerdVpnRecord(token = token, key = originalKey, state = "ready", revision = 3))
        val fetchedTokens = mutableListOf<String>()
        val manager = manager(store) { _, currentToken ->
            fetchedTokens.add(currentToken)
            NerdVpnKeyResult(200, key = replacementKey)
        }
        val intent = manager.beginAuth(account)["intent"] as Long
        val attempt = manager.resolve(account, video)
        assertEquals(true, manager.recover(account, "invalid_credentials", 401, null,
            attempt.apiKey, attempt.revision)["retryAllowed"])
        assertEquals(intent, store.read(account)?.intent)
        val authorized = manager.authorize(account, "new-fixture-token", intent)
        assertEquals("ready", authorized["state"])
        assertNull(authorized["superseded"])
        assertEquals(listOf(token, "new-fixture-token"), fetchedTokens)
        assertEquals("new-fixture-token", store.read(account)?.token)
    }

    @Test fun `old account response cannot retry or pause credentials committed by a newer sign-in`() {
        val store = MemoryStore()
        var fetches = 0
        val manager = manager(store) { _, _ ->
            fetches++
            NerdVpnKeyResult(200, key = if (fetches == 1) originalKey else replacementKey)
        }
        manager.authorize(account, token)
        val previousIdentity = manager.resolve(account, video).intent
        val pendingIntent = manager.beginAuth(account)["intent"] as Long
        val pendingRequest = manager.resolve(account, video)
        assertEquals(previousIdentity, pendingRequest.intent)
        manager.authorize(account, "new-fixture-token", pendingIntent)
        val newCredentials = store.read(account)
        assertNotEquals(pendingRequest.intent, newCredentials?.credentialIntent)
        val lateKeyFailure = manager.recover(account, "invalid_credentials", 401, null,
            pendingRequest.apiKey, pendingRequest.revision, failedIntent = pendingRequest.intent)
        assertEquals(false, lateKeyFailure["retryAllowed"])
        manager.recover(account, "rate_limited", 429, 120,
            pendingRequest.apiKey, pendingRequest.revision, failedIntent = pendingRequest.intent)
        assertEquals(newCredentials, store.read(account))
        assertEquals("new-fixture-token", store.read(account)?.token)
        assertEquals(2, fetches)
    }

    @Test fun `late cooldown after key rotation is retained and later waits extend the deadline`() {
        val store = MemoryStore()
        store.write(account, NerdVpnRecord(token = token, key = originalKey, state = "ready",
            revision = 9, credentialIntent = 7))
        val manager = manager(store) { _, _ -> NerdVpnKeyResult(200, key = replacementKey) }
        val attempt = manager.resolve(account, video)
        manager.recover(account, "invalid_credentials", 401, null, attempt.apiKey,
            attempt.revision, failedIntent = attempt.intent)
        assertEquals(replacementKey, manager.resolve(account, video).apiKey)
        manager.recover(account, "rate_limited", 429, 20, attempt.apiKey,
            attempt.revision, failedIntent = attempt.intent)
        assertEquals("unavailable", store.read(account)?.state)
        assertEquals(initialTime + 20_000, store.read(account)?.retryAt)
        manager.recover(account, "rate_limited", 429, 5, attempt.apiKey,
            attempt.revision, failedIntent = attempt.intent)
        assertEquals(initialTime + 20_000, store.read(account)?.retryAt)
        manager.recover(account, "unavailable", 503, 40, attempt.apiKey,
            attempt.revision, failedIntent = attempt.intent)
        assertEquals(initialTime + 40_000, store.read(account)?.retryAt)
        assertEquals(replacementKey, store.read(account)?.key)
        assertEquals(token, store.read(account)?.token)
        assertEquals(7L, store.read(account)?.credentialIntent)
    }

    @Test fun `late cooldown preserves terminal access states`() {
        for (state in listOf("waiting", "disabled", "denied", "signInRequired", "missing")) {
            val store = MemoryStore()
            store.write(account, NerdVpnRecord(token = token, state = state,
                revision = 5, credentialIntent = 7))
            val manager = manager(store)
            manager.recover(account, "rate_limited", 429, 20, originalKey, 3,
                failedIntent = 7)
            assertEquals(state, store.read(account)?.state)
            assertEquals(initialTime + 20_000, store.read(account)?.retryAt)
            assertEquals(token, store.read(account)?.token)
        }
    }

    @Test fun `legacy missing scope requests sign-in without erasing the token`() {
        val store = MemoryStore()
        val manager = manager(store) { _, _ -> NerdVpnKeyResult(403, error = "Invalid scope") }
        assertEquals("signInRequired", manager.authorize(account, token)["state"])
        assertEquals(token, store.read(account)?.token)
    }

    @Test fun `clear supersedes late failures and leaves other accounts usable`() {
        val store = MemoryStore()
        val manager = manager(store)
        manager.setKey(account, originalKey)
        manager.setKey(secondAccount, replacementKey)
        val old = manager.resolve(account, video)
        manager.clear(account)
        val late = manager.recover(account, "invalid_credentials", 401, null, old.apiKey, old.revision)
        assertEquals(false, late["retryAllowed"])
        assertEquals("missing", late["state"])
        assertNull(store.read(account)?.key)
        assertNull(store.read(account)?.token)
        assertEquals(replacementKey, manager.resolve(secondAccount, video).apiKey)
    }

    @Test fun `clear during recovery wins after the bounded pending request`() {
        val store = MemoryStore()
        store.write(account, NerdVpnRecord(token = token, key = originalKey, state = "ready", revision = 4))
        val recovering = CountDownLatch(1)
        val release = CountDownLatch(1)
        val manager = manager(store) { _, _ ->
            recovering.countDown()
            assertTrue(release.await(5, TimeUnit.SECONDS))
            NerdVpnKeyResult(200, key = replacementKey)
        }
        val executor = Executors.newFixedThreadPool(2)
        try {
            val recovery = executor.submit<Map<String, Any>> {
                manager.recover(account, "invalid_credentials", 401, null, originalKey, 4)
            }
            assertTrue(recovering.await(5, TimeUnit.SECONDS))
            val clearing = executor.submit<Map<String, Any>> { manager.clear(account) }
            release.countDown()
            recovery.get(5, TimeUnit.SECONDS)
            assertEquals("missing", clearing.get(5, TimeUnit.SECONDS)["state"])
            assertNull(store.read(account)?.token)
            assertNull(store.read(account)?.key)
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun `status and diagnostic strings exclude keys and account tokens`() {
        val store = MemoryStore()
        val manager = manager(store) { _, _ -> NerdVpnKeyResult(200, key = originalKey) }
        val status = manager.authorize(account, token)
        for (text in listOf(status.toString(), store.read(account).toString(),
            manager.resolve(account, video).toString(), NerdVpnKeyResult(200, key = originalKey).toString())) {
            assertFalse(text.contains(originalKey))
            assertFalse(text.contains(token))
        }
    }

    @Test fun `keys retain case and reject malformed values`() {
        val manager = manager(MemoryStore())
        for (key in listOf("nvpn_" + "A".repeat(31), "nvpn_" + "A".repeat(33),
            "NVPN_" + "A".repeat(32), originalKey + "\n", "nvpn_" + "-".repeat(32))) {
            assertThrows(IllegalArgumentException::class.java) { manager.setKey(account, key) }
        }
        manager.setKey(account, originalKey)
        assertEquals(originalKey, manager.resolve(account, video).apiKey)
        manager.setKey(account, originalKey.lowercase())
        assertEquals(originalKey.lowercase(), manager.resolve(account, video).apiKey)
    }

    @Test fun `legacy manual key is imported once and a stale header cannot replace its rotation`() {
        val store = MemoryStore()
        val manager = manager(store)
        assertEquals(originalKey, manager.resolve(account, video, originalKey).apiKey)
        assertEquals(originalKey, store.read(account)?.key)
        assertNull(store.read(account)?.token)
        manager.setKey(account, replacementKey)
        assertEquals(replacementKey, manager.resolve(account, video, originalKey).apiKey)
        assertNull(manager.resolve(secondAccount, video).apiKey)
    }

    @Test fun `a stale manual header cannot resurrect access after clear`() {
        val store = MemoryStore()
        val manager = manager(store)
        manager.resolve(account, video, originalKey)
        manager.clear(account)
        val cleared = store.read(account)
        val stale = manager.resolve(account, video, originalKey)
        assertNull(stale.apiKey)
        assertEquals("missing", stale.error)
        assertEquals(cleared, store.read(account))
    }

    @Test fun `stale manual key migration cannot replace a logout tombstone`() {
        val store = MemoryStore()
        val manager = manager(store)
        manager.clear(account)
        val cleared = store.read(account)
        val migrated = manager.setKey(account, originalKey, expectedRevision = 0)
        assertEquals(true, migrated["superseded"])
        assertEquals("missing", migrated["state"])
        assertEquals(cleared, store.read(account))
        assertNull(manager.resolve(account, video).apiKey)
    }

    @Test fun `manual key entry supersedes browser sign-in while transparent migration preserves it`() {
        for (transparentMigration in listOf(false, true)) {
            val store = MemoryStore()
            var fetches = 0
            val manager = manager(store) { _, _ ->
                fetches++
                NerdVpnKeyResult(200, key = replacementKey)
            }
            val intent = manager.beginAuth(account)["intent"] as Long
            if (transparentMigration) manager.setKey(account, originalKey, expectedRevision = 0)
            else manager.setKey(account, originalKey)
            val beforeAuthorization = store.read(account)
            val authorized = manager.authorize(account, token, intent)
            if (transparentMigration) {
                assertNull(authorized["superseded"])
                assertEquals("ready", authorized["state"])
                assertEquals(token, store.read(account)?.token)
                assertEquals(replacementKey, manager.resolve(account, video).apiKey)
                assertEquals(1, fetches)
            } else {
                assertEquals(true, authorized["superseded"])
                assertEquals(beforeAuthorization, store.read(account))
                assertNull(store.read(account)?.token)
                assertEquals(originalKey, manager.resolve(account, video).apiKey)
                assertEquals(0, fetches)
            }
        }
    }

    @Test fun `checking a ready manual key preserves access without a bearer token`() {
        val store = MemoryStore()
        val manager = manager(store)
        manager.setKey(account, originalKey)
        val before = store.read(account)
        assertEquals("ready", manager.check(account)["state"])
        assertEquals(before, store.read(account))
        assertEquals(originalKey, manager.resolve(account, video).apiKey)
    }

    @Test fun `ordinary upstream failures do not change gateway access state`() {
        val store = MemoryStore()
        val manager = manager(store)
        manager.setKey(account, originalKey)
        val before = store.read(account)
        manager.recover(account, "Upstream video failure", 503, null, originalKey, before!!.revision)
        manager.recover(account, "Unknown 403", 403, null, originalKey, before.revision)
        assertEquals(before, store.read(account))
        assertEquals(originalKey, manager.resolve(account, video).apiKey)
    }

    @Test fun `UTC eligibility timestamps accept valid fractional precision and reject invalid dates`() {
        val seconds = parseNerdVpnTimestamp("2026-11-14T09:30:00Z")!!
        assertEquals(seconds + 100, parseNerdVpnTimestamp("2026-11-14T09:30:00.1Z"))
        assertEquals(seconds + 120, parseNerdVpnTimestamp("2026-11-14T09:30:00.12Z"))
        assertEquals(seconds + 123, parseNerdVpnTimestamp("2026-11-14T09:30:00.123456Z"))
        assertNull(parseNerdVpnTimestamp("2026-02-30T09:30:00Z"))
        assertNull(parseNerdVpnTimestamp("2026-11-14T09:30:00+01:00"))
    }

    private fun manager(store: NerdVpnStore,
        fetch: (GatewayContext, String) -> NerdVpnKeyResult = { _, _ -> error("Unexpected key retrieval") }) =
        NerdVpnAccessManager(store, fetch) { initialTime }

    private class MemoryStore : NerdVpnStore {
        private val records = ConcurrentHashMap<String, NerdVpnRecord>()
        override fun read(context: GatewayContext): NerdVpnRecord? = records[context.key]
        override fun write(context: GatewayContext, record: NerdVpnRecord) { records[context.key] = record }
    }
}
