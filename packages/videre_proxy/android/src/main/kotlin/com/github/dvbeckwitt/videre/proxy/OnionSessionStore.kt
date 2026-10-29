package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject

private const val MAX_SESSION_AGE_MILLIS = 7L * 24 * 60 * 60 * 1000
private const val MAX_STORE_BYTES = 512 * 1024
private const val MAX_SESSIONS = 32

/** Origins accepted by the verification transport, without a network lookup. */
internal fun canonicalOnionOrigin(value: String): String? {
    if (value != value.trim() || value.any { it <= ' ' || it == '\u007f' || it == '\\' } ||
        value.contains('@')) return null
    val url = value.toHttpUrlOrNull() ?: return null
    if (url.scheme != "http" || url.port != 80 || !url.host.matches(Regex("[a-z2-7]{56}\\.onion")) ||
        url.username.isNotEmpty() || url.password.isNotEmpty() ||
        url.encodedPath != "/" || url.encodedQuery != null || url.encodedFragment != null) return null
    return "http://${url.host}"
}

/** Only the browser fingerprint and verified cookie can cross the native bridge. */
internal fun validatedOnionSessionHeaders(input: Map<*, *>): Map<String, String>? {
    val names = mapOf(
        "user-agent" to "User-Agent",
        "accept-language" to "Accept-Language",
        "accept-encoding" to "Accept-Encoding",
        "accept" to "Accept",
        "cookie" to "Cookie",
    )
    if (input.size != names.size) return null
    val headers = linkedMapOf<String, String>()
    var length = 0
    for ((rawName, rawValue) in input) {
        val name = (rawName as? String)?.lowercase(Locale.ROOT)?.let(names::get) ?: return null
        val value = rawValue as? String ?: return null
        if (headers.containsKey(name) || value.isBlank() || value.length > 32768 ||
            value.any { it < ' ' || it == '\u007f' }) return null
        length += value.length
        if (length > 131072) return null
        headers[name] = value
    }
    return headers
}

internal fun boundedOnionSessionExpiry(expiresAt: Long, now: Long): Long? {
    if (now < 0 || expiresAt <= now) return null
    val maximum = if (now > Long.MAX_VALUE - MAX_SESSION_AGE_MILLIS) Long.MAX_VALUE
        else now + MAX_SESSION_AGE_MILLIS
    return minOf(expiresAt, maximum)
}

/**
 * Sessions are encrypted with a device-local Android Keystore key and excluded
 * from Android backup. Each operation rereads under a file lock: the verifier
 * Activity and Flutter engines run in different processes and must not depend
 * on a SharedPreferences cache or overwrite one another's sessions.
 */
internal object OnionSessionStore {
    private const val KEY_ALIAS = "videre.onion.verification.sessions.v1"
    private const val FILE_NAME = "onion-verification-sessions.v1"
    private const val LOCK_NAME = "onion-verification-sessions.lock"
    private const val ENVELOPE_VERSION = 1

    @JvmStatic
    @Synchronized
    fun getAll(context: Context, policy: ProxyPolicy): Map<String, Map<String, Any>> {
        if (!policy.enabled) return emptyMap()
        return try {
            locked(context) {
                val now = System.currentTimeMillis()
                val records = readRecords(context, now)
                records.filterValues { it.policy == policy }.mapValues { it.value.result() }
            }
        } catch (_: Exception) {
            // No unverifiable or partially read credential can leave the store.
            // A later verified session may replace a corrupt/unreadable cache.
            emptyMap()
        }
    }

    @JvmStatic
    @Synchronized
    @Throws(IOException::class)
    fun save(
        context: Context,
        origin: String,
        headers: Map<String, String>,
        expiresAt: Long,
        policy: ProxyPolicy,
    ): Map<String, Any> {
        val canonical = canonicalOnionOrigin(origin)
        val validated = validatedOnionSessionHeaders(headers)
        val now = System.currentTimeMillis()
        val expiry = boundedOnionSessionExpiry(expiresAt, now)
        if (canonical == null || canonical != origin || validated == null || expiry == null || !policy.enabled) {
            throw IOException("The onion verification session is invalid.")
        }
        try {
            return locked(context) {
                val records = readRecords(context, now).toMutableMap()
                val record = Record(canonical, validated, expiry, policy)
                records[canonical] = record
                // Eviction affects cached verification only, never user accounts.
                while (records.size > MAX_SESSIONS) {
                    val oldest = records.filterKeys { it != canonical }.minByOrNull { it.value.expiresAt }
                        ?: break
                    records.remove(oldest.key)
                }
                writeRecords(context, records)
                record.result()
            }
        } catch (_: Exception) {
            throw IOException("Could not save the onion verification session.")
        }
    }

    @JvmStatic
    @Synchronized
    @Throws(IOException::class)
    fun remove(context: Context, origin: String) {
        val canonical = canonicalOnionOrigin(origin) ?: return
        try {
            locked(context) {
                val records = readRecords(context, System.currentTimeMillis()).toMutableMap()
                if (records.remove(canonical) != null) writeRecords(context, records)
            }
        } catch (_: Exception) {
            throw IOException("Could not clear the onion verification session.")
        }
    }

    private data class Record(
        val origin: String,
        val headers: Map<String, String>,
        val expiresAt: Long,
        val policy: ProxyPolicy,
    ) {
        fun result(): Map<String, Any> = mapOf("headers" to headers.toMap(), "expiresAt" to expiresAt)
        fun json(): JSONObject = JSONObject().apply {
            put("headers", JSONObject(headers))
            put("expiresAt", expiresAt)
            put("proxy", JSONObject(policy.toMap()))
        }
    }

    private fun <T> locked(context: Context, operation: () -> T): T {
        val directory = context.noBackupFilesDir
        if (!directory.exists() && !directory.mkdirs()) throw IOException("Session storage unavailable.")
        RandomAccessFile(File(directory, LOCK_NAME), "rw").use { file ->
            file.channel.use { channel -> channel.lock().use { return operation() } }
        }
    }

    private fun readRecords(context: Context, now: Long): Map<String, Record> {
        val file = AtomicFile(File(context.noBackupFilesDir, FILE_NAME))
        val result = linkedMapOf<String, Record>()
        try {
            val encrypted = file.openRead().use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count > MAX_STORE_BYTES - output.size()) throw IOException("Session storage too large.")
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            val records = JSONObject(String(decrypt(context, encrypted), StandardCharsets.UTF_8))
            if (records.length() > MAX_SESSIONS) return emptyMap()
            for (origin in records.keys()) {
                if (canonicalOnionOrigin(origin) != origin) continue
                val record = records.optJSONObject(origin) ?: continue
                val rawHeaders = record.optJSONObject("headers") ?: continue
                val headers = validatedOnionSessionHeaders(rawHeaders.keys().asSequence()
                    .associateWith { rawHeaders.get(it) }) ?: continue
                val rawExpiry = record.opt("expiresAt")
                if (rawExpiry !is Long && rawExpiry !is Int) continue
                val expiry = (rawExpiry as Number).toLong()
                // Do not move a persisted absolute deadline forward while reading.
                if (expiry <= now || boundedOnionSessionExpiry(expiry, now) != expiry) continue
                val proxy = record.optJSONObject("proxy") ?: continue
                val policy = try {
                    ProxyPolicy.fromMap(proxy.keys().asSequence().associateWith { proxy.get(it) })
                } catch (_: Exception) { continue }
                if (!policy.enabled) continue
                result[origin] = Record(origin, headers, expiry, policy)
            }
        } catch (_: Exception) {
            return emptyMap()
        }
        return result
    }

    private fun writeRecords(context: Context, records: Map<String, Record>) {
        val json = JSONObject()
        records.forEach { (origin, record) -> json.put(origin, record.json()) }
        val clear = json.toString().toByteArray(StandardCharsets.UTF_8)
        if (clear.size > MAX_STORE_BYTES - 64) throw IOException("Session storage too large.")
        val encrypted = encrypt(context, clear)
        val file = AtomicFile(File(context.noBackupFilesDir, FILE_NAME))
        val output = file.startWrite()
        try {
            output.write(encrypted)
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(KEY_ALIAS, null)
        if (existing is SecretKey) return existing
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(
            KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build())
        return generator.generateKey()
    }

    private fun associatedData(context: Context): ByteArray =
        ("Videre onion verification v1\n" + context.packageName).toByteArray(StandardCharsets.UTF_8)

    private fun encrypt(context: Context, clear: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(associatedData(context))
        val encrypted = cipher.doFinal(clear)
        return ByteArrayOutputStream().also { output ->
            DataOutputStream(output).use { data ->
                data.writeByte(ENVELOPE_VERSION)
                data.writeByte(cipher.iv.size)
                data.write(cipher.iv)
                data.write(encrypted)
            }
        }.toByteArray()
    }

    private fun decrypt(context: Context, bytes: ByteArray): ByteArray {
        DataInputStream(ByteArrayInputStream(bytes)).use { input ->
            if (input.readUnsignedByte() != ENVELOPE_VERSION || input.readUnsignedByte() != 12) {
                throw IOException("Invalid session storage.")
            }
            val iv = ByteArray(12).also(input::readFully)
            val encrypted = ByteArray(input.available()).also(input::readFully)
            if (encrypted.size < 16) throw IOException("Invalid session storage.")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
            cipher.updateAAD(associatedData(context))
            return cipher.doFinal(encrypted)
        }
    }
}
