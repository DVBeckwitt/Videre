package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import android.util.Base64
import java.io.IOException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.SecretKey
import org.json.JSONObject
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises Android Keystore with fixture credentials and no network traffic. */
@RunWith(AndroidJUnit4::class)
class NerdVpnStorageDeviceTest {
    private val target = InstrumentationRegistry.getInstrumentation().targetContext
    private val origin = "https://invidious.nerdvpn.de".toHttpUrl()
    private val first = GatewayContext("0247ed8b-e84e-5b9e-9ab6-aa534f64c031", origin)
    private val second = GatewayContext("0247ed8b-e84e-5b9e-9ab6-aa534f64c032", origin)
    private val preferences = target.getSharedPreferences(NERDVPN_PREFERENCES, Context.MODE_PRIVATE)
    private val saved = mutableMapOf<String, String?>()
    private val fixture = NerdVpnRecord(
        token = "fixture-only-account-token",
        key = "nvpn_" + "K".repeat(32),
        state = "unavailable",
        retryAt = 1_800_000_123_000,
        revision = 9,
        intent = 12,
        credentialIntent = 8,
    )

    @Before fun retainFixtureSlots() {
        for (account in listOf(first, second)) {
            val name = "account_${account.key}"
            saved[name] = preferences.getString(name, null)
        }
    }

    @After fun restoreFixtureSlots() {
        val edit = preferences.edit()
        for ((name, value) in saved) {
            if (value == null) edit.remove(name) else edit.putString(name, value)
        }
        assertTrue(edit.commit())
    }

    @Test fun encryptedAccountsSurviveStoreReconstructionAndKeepSecretsOutOfPreferences() {
        val store = EncryptedNerdVpnStore(target)
        store.write(first, fixture)
        store.write(second, fixture.copy(token = "second-fixture-token", key = "nvpn_" + "Z".repeat(32), revision = 12))
        val encrypted = preferences.getString("account_${first.key}", null)!!
        assertFalse(encrypted.contains(fixture.token!!))
        assertFalse(encrypted.contains(fixture.key!!))

        val reopened = EncryptedNerdVpnStore(target)
        assertEquals(fixture, reopened.read(first))
        assertEquals("second-fixture-token", reopened.read(second)?.token)
        store.write(first, fixture)
        assertNotEquals("Repeated saves must use independent GCM nonces", encrypted,
            preferences.getString("account_${first.key}", null))

        store.write(first, NerdVpnRecord(revision = fixture.revision + 1))
        assertNull(reopened.read(first)?.key)
        assertNull(reopened.read(first)?.token)
        assertEquals("second-fixture-token", reopened.read(second)?.token)
    }

    @Test fun legacyMixedCooldownReleasesTheKeyAndKeepsWaitingAccountsPending() {
        val store = EncryptedNerdVpnStore(target)
        store.write(first, fixture)
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val secret = keys.getKey("videre_nerdvpn_access_v1", null) as SecretKey
        for (oldState in listOf("unavailable", "waiting")) {
            val json = JSONObject().put("state", oldState).put("revision", fixture.revision)
                .put("token", fixture.token).put("retryAt", Long.MAX_VALUE)
                .put("key", fixture.key.takeIf { oldState == "unavailable" })
                .put("availableAt", fixture.retryAt.takeIf { oldState == "waiting" })
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.ENCRYPT_MODE, secret)
                updateAAD("${first.key}|${first.origin}".toByteArray(Charsets.UTF_8))
            }
            val bytes = byteArrayOf(1) + cipher.iv + cipher.doFinal(json.toString().toByteArray(Charsets.UTF_8))
            assertTrue(preferences.edit().putString("account_${first.key}", Base64.encodeToString(bytes, Base64.NO_WRAP)).commit())
            val reopened = store.read(first)!!
            assertNull(reopened.retryAt)
            assertEquals(fixture.token, reopened.token)
            assertEquals(fixture.revision, reopened.revision)
            if (oldState == "waiting") {
                assertEquals("waiting", reopened.state)
                assertEquals(fixture.retryAt, reopened.availableAt)
            } else {
                assertEquals("ready", reopened.state)
                assertEquals(fixture.key, reopened.key)
            }
        }
    }

    @Test fun accountOriginBindingRejectsMovedOrModifiedCiphertext() {
        val store = EncryptedNerdVpnStore(target)
        store.write(first, fixture)
        val ciphertext = preferences.getString("account_${first.key}", null)!!
        assertTrue(preferences.edit().putString("account_${second.key}", ciphertext).commit())
        assertThrows(IOException::class.java) { store.read(second) }
        assertThrows(IOException::class.java) {
            store.read(first.copy(origin = "https://other.example".toHttpUrl()))
        }
        assertTrue(preferences.edit().putString("account_${first.key}", "corrupted-ciphertext").commit())
        val exception = assertThrows(IOException::class.java) { store.read(first) }
        assertFalse(exception.message.orEmpty().contains(fixture.token!!))
        assertFalse(exception.message.orEmpty().contains(fixture.key!!))
    }
}
