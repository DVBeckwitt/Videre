package com.github.dvbeckwitt.videre.proxy

import android.content.SharedPreferences
import org.junit.Assert.*
import org.junit.Test

class GatewaySessionRecoveryTest {
    @Test fun interruptedReauthenticationKeepsCompletedSessionAndInvalidatesOldRevision() {
        val preferences = MemoryPreferences(completedSession + mapOf(
            "pending_account" to true,
            "pendingProfile_account" to "videre_gateway_account_8",
            "revision_account" to 8L,
            "cancelledRevision_account" to 6L,
        ))

        assertEquals(listOf("videre_gateway_account_8"), recoverInterruptedGatewaySignIns(preferences))

        assertEquals(completedSession + ("revision_account" to 9L), preferences.all)
        assertTrue(recoverInterruptedGatewaySignIns(preferences).isEmpty())
        assertEquals(9L, preferences.getLong("revision_account", 0L))
    }

    @Test fun recoveryPreservesAnAuthenticationFailure() {
        val preferences = MemoryPreferences(completedSession + mapOf(
            "expired_account" to true,
            "pending_account" to true,
            "pendingProfile_account" to "videre_gateway_account_8",
            "revision_account" to 8L,
        ))
        recoverInterruptedGatewaySignIns(preferences)
        assertTrue(preferences.getBoolean("expired_account", false))
        assertEquals("videre_gateway_account_7", preferences.getString("profile_account", null))
    }

    @Test fun firstLoginRemainsProtectedUntilItCompletes() {
        val initial = mapOf<String, Any>("pending_account" to true,
            "pendingProfile_account" to "videre_gateway_account_1", "revision_account" to 1L)
        val preferences = MemoryPreferences(initial)
        assertTrue(recoverInterruptedGatewaySignIns(preferences).isEmpty())
        assertEquals(initial, preferences.all)
    }

    @Test fun recoveryDoesNotChangeOtherAccountsOrRevocationTombstones() {
        val other = mapOf<String, Any>(
            "origin_other" to "https://other.example/", "profile_other" to "other_profile",
            "revision_other" to 14L, "expired_other" to true,
            "revision_revoked" to 20L, "cancelledRevision_revoked" to 19L,
        )
        val preferences = MemoryPreferences(completedSession + other + mapOf(
            "pending_account" to true, "pendingProfile_account" to "pending_profile",
        ))
        assertEquals(listOf("pending_profile"), recoverInterruptedGatewaySignIns(preferences))
        assertEquals(completedSession + other + ("revision_account" to 8L), preferences.all)
    }

    @Test fun completedProfileIsNeverScheduledForCleanup() {
        val preferences = MemoryPreferences(completedSession + mapOf(
            "pending_account" to true, "pendingProfile_account" to "videre_gateway_account_7",
        ))
        assertTrue(recoverInterruptedGatewaySignIns(preferences).isEmpty())
        assertFalse(preferences.getBoolean("pending_account", false))
        assertEquals("videre_gateway_account_7", preferences.getString("profile_account", null))
    }

    @Test fun unsuccessfulPersistenceDoesNotExposeRecoveredSession() {
        val initial = completedSession + mapOf("pending_account" to true)
        val preferences = MemoryPreferences(initial, failCommit = true)
        assertThrows(IllegalStateException::class.java) { recoverInterruptedGatewaySignIns(preferences) }
        assertEquals(initial, preferences.all)
    }

    private val completedSession = mapOf<String, Any>(
        "origin_account" to "https://gateway-fixture.example/",
        "profile_account" to "videre_gateway_account_7",
        "revision_account" to 7L,
        "expired_account" to false,
    )
}

private class MemoryPreferences(initial: Map<String, Any>, private val failCommit: Boolean = false) : SharedPreferences {
    private val values = initial.toMutableMap()
    override fun getAll(): Map<String, *> = values.toMap()
    override fun getString(key: String?, defValue: String?): String? = values[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        (values[key] as? Set<String>)?.toMutableSet() ?: defValues
    override fun getInt(key: String?, defValue: Int): Int = values[key] as? Int ?: defValue
    override fun getLong(key: String?, defValue: Long): Long = values[key] as? Long ?: defValue
    override fun getFloat(key: String?, defValue: Float): Float = values[key] as? Float ?: defValue
    override fun getBoolean(key: String?, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
    override fun contains(key: String?): Boolean = values.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val changes = mutableMapOf<String, Any?>()
        private var clear = false
        override fun putString(key: String, value: String?) = apply { changes[key] = value }
        override fun putStringSet(key: String, values: MutableSet<String>?) = apply { changes[key] = values?.toSet() }
        override fun putInt(key: String, value: Int) = apply { changes[key] = value }
        override fun putLong(key: String, value: Long) = apply { changes[key] = value }
        override fun putFloat(key: String, value: Float) = apply { changes[key] = value }
        override fun putBoolean(key: String, value: Boolean) = apply { changes[key] = value }
        override fun remove(key: String) = apply { changes[key] = null }
        override fun clear() = apply { clear = true }
        override fun commit(): Boolean {
            if (failCommit) return false
            if (clear) values.clear()
            changes.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }
            return true
        }
        override fun apply() { commit() }
    }
}
