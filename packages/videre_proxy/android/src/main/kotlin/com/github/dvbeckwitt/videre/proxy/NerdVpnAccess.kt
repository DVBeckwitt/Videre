package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.IOException
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

internal const val NERDVPN_PREFERENCES = "videre_nerdvpn_access"

/** API keys and the native copy of recovery credentials are encrypted separately
 * from Flutter account data. GCM binds each ciphertext to its account and origin. */
internal class EncryptedNerdVpnStore(context: Context) : NerdVpnStore {
    private val preferences = context.applicationContext.getSharedPreferences(NERDVPN_PREFERENCES, Context.MODE_PRIVATE)
    private val keyAlias = "videre_nerdvpn_access_v1"

    private fun secretKey(): SecretKey = synchronized(EncryptedNerdVpnStore::class.java) {
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keys.getKey(keyAlias, null) as? SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(keyAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }

    private fun aad(context: GatewayContext) = "${context.key}|${context.origin}".toByteArray(Charsets.UTF_8)

    override fun read(context: GatewayContext): NerdVpnRecord? {
        val stored = preferences.getString("account_${context.key}", null) ?: return null
        try {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            require(bytes.size > 28 && bytes[0] == 1.toByte())
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
            cipher.updateAAD(aad(context))
            val json = JSONObject(String(cipher.doFinal(bytes.copyOfRange(13, bytes.size)), Charsets.UTF_8))
            return NerdVpnRecord(
                token = json.optString("token").takeIf { it.isNotEmpty() },
                key = json.optString("key").takeIf { validNerdVpnKey(it) },
                state = json.getString("state"),
                availableAt = if (json.has("availableAt")) json.getLong("availableAt") else null,
                retryAt = if (json.has("retryAt")) json.getLong("retryAt") else null,
                revision = json.getLong("revision"),
                intent = json.optLong("intent", 0),
                credentialIntent = json.optLong("credentialIntent", 0),
            )
        } catch (_: Exception) {
            throw IOException("The saved NerdVPN API access is unavailable.")
        }
    }

    override fun write(context: GatewayContext, record: NerdVpnRecord) {
        try {
            val json = JSONObject().put("state", record.state).put("revision", record.revision)
                .put("intent", record.intent)
                .put("credentialIntent", record.credentialIntent)
                .put("token", record.token).put("key", record.key)
                .put("availableAt", record.availableAt).put("retryAt", record.retryAt)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secretKey())
            cipher.updateAAD(aad(context))
            val encrypted = byteArrayOf(1) + cipher.iv + cipher.doFinal(json.toString().toByteArray(Charsets.UTF_8))
            check(preferences.edit().putString("account_${context.key}", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit())
        } catch (_: Exception) {
            throw IOException("NerdVPN API access could not be saved.")
        }
    }
}

internal object NerdVpnAccess {
    @Volatile private var instance: NerdVpnAccessManager? = null

    @Synchronized fun initialize(context: Context) {
        if (instance == null) instance = NerdVpnAccessManager(EncryptedNerdVpnStore(context), ::fetchKey)
    }

    private fun manager() = instance ?: throw IOException("NerdVPN API access is unavailable.")

    fun status(context: GatewayContext) = manager().status(context)
    fun beginAuth(context: GatewayContext) = manager().beginAuth(context)
    fun authorize(context: GatewayContext, token: String, intent: Long) = manager().authorize(context, token, intent)
    fun check(context: GatewayContext) = manager().check(context)
    fun setKey(context: GatewayContext, key: String, expectedRevision: Long? = null) = manager().setKey(context, key, expectedRevision)
    fun clear(context: GatewayContext) = manager().clear(context)

    fun resolve(context: GatewayContext, url: HttpUrl, manualKey: String? = null): NerdVpnResolvedAccess {
        if (!isNerdVpnOrigin(context.origin) || !context.allows(url) || isNerdVpnBootstrap(url)) return NerdVpnResolvedAccess()
        return manager().resolve(context, url, manualKey)
    }

    fun recover(context: GatewayContext, error: String?, statusCode: Int, retryAfterSeconds: Long?,
        failedKey: String?, revision: Long?, retry: Boolean = true, failedIntent: Long? = null) =
        manager().recover(context, error, statusCode, retryAfterSeconds, failedKey, revision, retry, failedIntent)

    private fun fetchKey(context: GatewayContext, token: String): NerdVpnKeyResult {
        val request = Request.Builder().url(context.origin.resolve("/api/v1/auth/api_key")!!)
            .tag(GatewayRequestScope::class.java, GatewayRequestScope(context))
            .header("Authorization", "Bearer $token")
            .header("Accept", "application/json")
            .post("{}".toRequestBody("application/json".toMediaType())).build()
        val call = ProxyDataSource.newApiCall(request, ApiRedirectOptions(followRedirects = false, maxRedirects = 0))
        call.timeout().timeout(30, TimeUnit.SECONDS)
        return call.execute().use { response ->
            val body = response.peekBody(65537)
            val json = if (body.contentLength() > 65536) null else runCatching { JSONObject(body.string()) }.getOrNull()
            NerdVpnKeyResult(response.code, json?.optString("error")?.takeIf { it.isNotEmpty() },
                json?.optString("api_key")?.takeIf { validNerdVpnKey(it) },
                json?.optString("api_key_available_at")?.let(::parseNerdVpnTimestamp),
                response.header("Retry-After")?.toLongOrNull())
        }
    }
}
