package com.github.dvbeckwitt.videre.proxy

import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap
import okhttp3.HttpUrl

const val NERDVPN_KEY_HEADER = "X-Invidious-Token"
const val NERDVPN_ONION_HOST = "nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion"

fun isNerdVpnOrigin(url: HttpUrl): Boolean = url.username.isEmpty() && url.password.isEmpty() &&
    when (url.host) {
        "invidious.nerdvpn.de" -> url.isHttps && url.port == 443
        NERDVPN_ONION_HOST -> (url.isHttps && url.port == 443) || (url.scheme == "http" && url.port == 80)
        else -> false
    }

internal fun isNerdVpnBootstrap(url: HttpUrl): Boolean =
    url.encodedPath in setOf("/api/v1/token", "/api/v1/auth/api_key")

internal fun validNerdVpnKey(value: String): Boolean = Regex("nvpn_[A-Za-z0-9]{32}").matches(value)

internal fun nerdVpnTimestamp(millis: Long): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT)
    .apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date(millis))

internal fun parseNerdVpnTimestamp(value: String): Long? {
    if (!Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d{1,9})?Z").matches(value)) return null
    val pattern = if (value.contains('.')) "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'" else "yyyy-MM-dd'T'HH:mm:ss'Z'"
    val normalized = if (value.contains('.')) value.substringBefore('.') + "." +
        value.substringAfter('.').removeSuffix("Z").take(3).padEnd(3, '0') + "Z" else value
    return runCatching {
        SimpleDateFormat(pattern, Locale.ROOT).apply {
            timeZone = TimeZone.getTimeZone("UTC")
            isLenient = false
        }.parse(normalized)?.time
    }.getOrNull()
}

internal data class NerdVpnRecord(
    val token: String? = null,
    val key: String? = null,
    val state: String = "missing",
    val availableAt: Long? = null,
    val retryAt: Long? = null,
    val revision: Long = 0,
    // Browser reservation changes before credentials do. Requests retain the
    // committed identity until a successful authorization replaces it.
    val intent: Long = 0,
    val credentialIntent: Long = 0,
) {
    override fun toString() = "NerdVpnRecord(state=$state, revision=$revision)"
}

internal interface NerdVpnStore {
    fun read(context: GatewayContext): NerdVpnRecord?
    fun write(context: GatewayContext, record: NerdVpnRecord)
}

internal data class NerdVpnKeyResult(
    val statusCode: Int,
    val error: String? = null,
    val key: String? = null,
    val availableAt: Long? = null,
    val retryAfterSeconds: Long? = null,
) {
    override fun toString() = "NerdVpnKeyResult(statusCode=$statusCode, error=$error)"
}

internal data class NerdVpnResolvedAccess(val apiKey: String? = null, val revision: Long? = null,
    val error: String? = null, val intent: Long? = null) {
    override fun toString() = "NerdVpnResolvedAccess(revision=$revision, error=$error)"
}

class NerdVpnAccessRequired(val state: String) : IOException("NerdVPN API access requires attention.")

/** One account lock covers persisted changes and the bounded key request. Native
 * media, foreground Flutter and Workmanager share this process-wide manager. */
internal class NerdVpnAccessManager(
    private val store: NerdVpnStore,
    private val fetch: (GatewayContext, String) -> NerdVpnKeyResult,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val locks = ConcurrentHashMap<String, Any>()
    private fun lock(context: GatewayContext): Any {
        require(isNerdVpnOrigin(context.origin)) { "Unsupported API key origin." }
        return locks.getOrPut(context.key) { Any() }
    }

    private fun read(context: GatewayContext) = store.read(context) ?: NerdVpnRecord()
    private fun status(record: NerdVpnRecord): Map<String, Any> = buildMap {
        put("state", record.state)
        put("revision", record.revision)
        put("apiKeyIntent", record.credentialIntent)
        record.availableAt?.let { put("availableAt", nerdVpnTimestamp(it)) }
        record.retryAt?.let { put("retryAt", nerdVpnTimestamp(it)) }
    }

    fun status(context: GatewayContext): Map<String, Any> = synchronized(lock(context)) { status(read(context)) }

    fun beginAuth(context: GatewayContext): Map<String, Any> = synchronized(lock(context)) {
        val old = read(context)
        val record = old.copy(intent = old.intent + 1)
        store.write(context, record)
        mapOf("intent" to record.intent)
    }

    fun authorize(context: GatewayContext, token: String, intent: Long? = null): Map<String, Any> = synchronized(lock(context)) {
        require(token.isNotBlank() && token.length <= 65536 && token.none { it == '\r' || it == '\n' })
        val old = read(context)
        if (intent != null && intent != old.intent) return@synchronized status(old) + ("superseded" to true)
        val record = NerdVpnRecord(token = token, revision = old.revision + 1, intent = old.intent,
            credentialIntent = old.credentialIntent + 1)
        store.write(context, record)
        status(requestKey(context, record))
    }

    fun check(context: GatewayContext): Map<String, Any> = synchronized(lock(context)) {
        val record = read(context)
        if ((record.state == "ready" && record.key != null && record.token == null) ||
            (record.retryAt ?: 0) > now()) status(record)
        else status(requestKey(context, record))
    }

    fun setKey(context: GatewayContext, key: String, expectedRevision: Long? = null): Map<String, Any> = synchronized(lock(context)) {
        require(validNerdVpnKey(key)) { "Invalid API key." }
        val old = read(context)
        if (expectedRevision != null && expectedRevision != old.revision) return@synchronized status(old) + ("superseded" to true)
        val record = old.copy(key = key, state = "ready", availableAt = null, retryAt = null,
            revision = old.revision + 1, intent = old.intent + if (expectedRevision == null) 1 else 0,
            credentialIntent = old.credentialIntent + if (expectedRevision == null) 1 else 0)
        store.write(context, record)
        status(record)
    }

    fun clear(context: GatewayContext): Map<String, Any> = synchronized(lock(context)) {
        // Keep only a tombstone revision so late failures cannot restore a login.
        val old = read(context)
        val record = NerdVpnRecord(revision = old.revision + 1, intent = old.intent + 1,
            credentialIntent = old.credentialIntent + 1)
        store.write(context, record)
        status(record)
    }

    fun resolve(context: GatewayContext, url: HttpUrl, manualKey: String? = null): NerdVpnResolvedAccess {
        if (!isNerdVpnOrigin(context.origin) || !context.allows(url) || isNerdVpnBootstrap(url)) return NerdVpnResolvedAccess()
        return synchronized(lock(context)) {
            var record = read(context)
            if (record.state == "missing" && record.revision == 0L && record.key == null &&
                manualKey != null && validNerdVpnKey(manualKey)) {
                record = record.copy(key = manualKey, state = "ready", revision = record.revision + 1)
                store.write(context, record)
            }
            if (record.state == "proxyRequired") {
                record = requestKey(context, record)
            } else if (record.state == "unavailable" && (record.retryAt ?: 0) <= now()) {
                record = if (record.key != null) record.copy(state = "ready", retryAt = null)
                    else requestKey(context, record)
                store.write(context, record)
            } else if (record.state == "waiting" && record.availableAt != null && record.availableAt <= now() &&
                (record.retryAt ?: 0) <= now()) {
                record = requestKey(context, record)
            }
            if (record.state == "ready" && record.key != null)
                NerdVpnResolvedAccess(record.key, record.revision, intent = record.credentialIntent)
            else NerdVpnResolvedAccess(revision = record.revision, error = record.state, intent = record.credentialIntent)
        }
    }

    fun recover(context: GatewayContext, error: String?, statusCode: Int, retryAfterSeconds: Long?,
        failedKey: String?, revision: Long?, retry: Boolean = true,
        failedIntent: Long? = null): Map<String, Any> = synchronized(lock(context)) {
        var record = read(context)
        if (failedIntent != null && failedIntent != record.credentialIntent)
            return@synchronized status(record) + ("retryAllowed" to false)
        val keyError = error in setOf("credentials_required", "invalid_credentials") && statusCode == 401
        val superseded = revision != null && revision != record.revision ||
            failedKey != null && record.key != null && failedKey != record.key
        if (keyError && superseded)
            return@synchronized status(record) + ("retryAllowed" to (record.state == "ready" && retry))
        if (keyError) {
            if (!retry) {
                record = record.copy(key = null, state = "signInRequired", retryAt = null, revision = record.revision + 1)
                store.write(context, record)
            } else if (record.state !in setOf("waiting", "disabled", "denied", "signInRequired") &&
                (record.retryAt ?: 0) <= now()) {
                record = requestKey(context, record)
            }
        } else if (error == "access_denied" && statusCode == 403) {
            record = record.copy(state = "denied", retryAt = null, revision = record.revision + 1)
            store.write(context, record)
        } else if ((error == "rate_limited" && statusCode == 429) || (error == "unavailable" && statusCode == 503)) {
            val state = if (record.state in setOf("waiting", "disabled", "denied", "signInRequired", "missing"))
                record.state else "unavailable"
            record = record.copy(state = state, retryAt = maxOf(record.retryAt ?: 0, retryTime(retryAfterSeconds)),
                revision = record.revision + 1)
            store.write(context, record)
        }
        status(record) + ("retryAllowed" to (keyError && retry && record.state == "ready"))
    }

    private fun retryTime(seconds: Long?): Long {
        val delay = seconds?.takeIf { it >= 1 && it <= (Long.MAX_VALUE - now()) / 1000 } ?: 30
        return now() + delay * 1000
    }

    private fun requestKey(context: GatewayContext, current: NerdVpnRecord): NerdVpnRecord {
        val token = current.token
        val record = if (token == null) current.copy(state = "signInRequired", revision = current.revision + 1)
        else {
            val response = try { fetch(context, token) } catch (error: IOException) {
                NerdVpnKeyResult(0, error = if (error is NerdVpnAccessRequired && error.state == "proxyRequired")
                    error.state else null)
            }
            val next = current.copy(revision = current.revision + 1, availableAt = null, retryAt = null)
            when {
                // Local configuration can be fixed immediately; keep credentials and avoid a server cooldown.
                response.statusCode == 0 && response.error == "proxyRequired" -> next.copy(state = "proxyRequired")
                response.statusCode == 200 && response.key != null && validNerdVpnKey(response.key) ->
                    next.copy(key = response.key, state = "ready")
                response.statusCode == 403 && response.error == "not_yet_eligible" && response.availableAt != null ->
                    next.copy(key = null, state = "waiting", availableAt = response.availableAt)
                response.statusCode == 403 && response.error == "access_disabled" -> next.copy(key = null, state = "disabled")
                response.statusCode == 403 && response.error == "access_denied" -> next.copy(state = "denied")
                response.statusCode in setOf(401, 403) -> next.copy(state = "signInRequired")
                else -> next.copy(state = "unavailable", retryAt = retryTime(response.retryAfterSeconds))
            }
        }
        store.write(context, record)
        return record
    }
}
