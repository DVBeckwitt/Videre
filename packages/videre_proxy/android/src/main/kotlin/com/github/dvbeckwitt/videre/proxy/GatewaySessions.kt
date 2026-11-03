package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewFeature
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import okhttp3.HttpUrl

/**
 * Chromium's app-private, account-isolated profile owns cookie scope and expiry.
 * Preferences store only origin, revision and status; no copied cookie headers.
 * The app excludes WebView data and this status file from backup/transfer.
 */
object GatewaySessions : GatewayCookieAccess {
    private val main = Handler(Looper.getMainLooper())
    private var preferences: SharedPreferences? = null

    @Synchronized fun initialize(context: Context) {
        if (preferences == null) preferences = context.applicationContext
            .getSharedPreferences("videre_gateway_sessions", Context.MODE_PRIVATE)
        GatewayCookieAccessRegistry.provider = this
    }

    fun supported(): Boolean = onMain {
        runCatching { WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE) }.getOrDefault(false)
    }

    private fun store(): SharedPreferences = preferences ?: throw GatewaySessionUnavailable()
    private fun enabled(context: GatewayContext) = store().getString("origin_${context.key}", null) == context.origin.toString()
    private fun revision(context: GatewayContext) = store().getLong("revision_${context.key}", 0)

    fun status(context: GatewayContext): Map<String, Any> = onMain {
        val available = supported()
        val pending = store().getBoolean("pending_${context.key}", false)
        val active = enabled(context) || pending
        mapOf("supported" to available, "enabled" to active,
            "revision" to revision(context),
            "needsSignIn" to (active && (!available || pending || store().getBoolean("expired_${context.key}", false))))
    }

    /** Called on the UI thread before attaching a WebView to this profile. */
    fun beginSignIn(context: GatewayContext): Long = onMain {
        if (!supported()) throw GatewaySessionUnavailable()
        val next = revision(context) + 1
        val profileName = "${context.profileName}_$next"
        check(store().edit().putLong("revision_${context.key}", next)
            .remove("cancelledRevision_${context.key}")
            .putBoolean("pending_${context.key}", true)
            .putString("pendingProfile_${context.key}", profileName).commit())
        ProfileStore.getInstance().getOrCreateProfile(profileName)
        next
    }

    fun signInProfileName(context: GatewayContext, expectedRevision: Long): String = onMain {
        check(revision(context) == expectedRevision && store().getBoolean("pending_${context.key}", false))
        store().getString("pendingProfile_${context.key}", null) ?: throw GatewaySessionUnavailable()
    }

    fun completeSignIn(context: GatewayContext, expectedRevision: Long): Boolean = onMain {
        if (!supported() || revision(context) != expectedRevision) return@onMain false
        val profileName = signInProfileName(context, expectedRevision)
        val previous = store().getString("profile_${context.key}", null)
        val manager = ProfileStore.getInstance().getOrCreateProfile(profileName).cookieManager
        manager.flush()
        val saved = store().edit().putString("origin_${context.key}", context.origin.toString())
            .remove("cancelledRevision_${context.key}")
            .putString("profile_${context.key}", profileName)
            .remove("pending_${context.key}").remove("pendingProfile_${context.key}")
            .putBoolean("expired_${context.key}", false).commit()
        if (saved && previous != null && previous != profileName) clearProfile(previous)
        saved
    }

    fun cancelSignIn(context: GatewayContext, expectedRevision: Long) = onMain {
        if (revision(context) == expectedRevision) {
            val pendingProfile = store().getString("pendingProfile_${context.key}", null)
            check(store().edit().remove("pending_${context.key}")
                .remove("pendingProfile_${context.key}")
                .putLong("cancelledRevision_${context.key}", expectedRevision)
                .putLong("revision_${context.key}", expectedRevision + 1).commit())
            if (pendingProfile != null) clearProfile(pendingProfile)
        }
        Unit
    }

    fun signOut(context: GatewayContext, expectedRevision: Long? = null) {
        val clearing = onMain {
            if (expectedRevision != null && revision(context) != expectedRevision &&
                !(revision(context) == expectedRevision + 1 &&
                    store().getLong("cancelledRevision_${context.key}", -1) == expectedRevision)) {
                return@onMain emptyList<CountDownLatch>()
            }
            val names = listOfNotNull(store().getString("profile_${context.key}", null),
                store().getString("pendingProfile_${context.key}", null)).distinct()
            check(store().edit().remove("origin_${context.key}")
                .remove("expired_${context.key}").remove("profile_${context.key}")
                .remove("cancelledRevision_${context.key}")
                .remove("pending_${context.key}").remove("pendingProfile_${context.key}")
                .putLong("revision_${context.key}", revision(context) + 1).commit())
            if (supported()) names.map { clearProfile(it) } else emptyList()
        }
        // Never block the UI thread on a CookieManager callback to that thread.
        if (Looper.myLooper() != Looper.getMainLooper()) clearing.forEach {
            if (!it.await(10, TimeUnit.SECONDS)) throw GatewaySessionUnavailable()
        }
    }

    override fun resolve(context: GatewayContext, url: HttpUrl): GatewayCookies = onMain {
        if (context.allows(url) && store().getBoolean("pending_${context.key}", false)) {
            return@onMain GatewayCookies(true, true, revision = revision(context))
        }
        if (!context.allows(url) || !enabled(context)) return@onMain GatewayCookies(false, false)
        if (!supported() || store().getBoolean("expired_${context.key}", false)) {
            return@onMain GatewayCookies(true, true, revision = revision(context))
        }
        GatewayCookies(true, false, cookieManager(context).getCookie(url.toString()), revision(context))
    }

    override fun ingest(context: GatewayContext, url: HttpUrl, cookies: List<String>,
        statusCode: Int, contentType: String?, location: String?, revision: Long?): Boolean = onMain {
        if (!context.allows(url) || !enabled(context) || revision == null ||
            revision != revision(context)) return@onMain false
        if (!supported()) return@onMain true
        require(cookies.size <= 100 && cookies.all { it.length <= 16384 }) { "Invalid server cookies." }
        val manager = cookieManager(context)
        cookies.forEach { manager.setCookie(url.toString(), it) }
        if (cookies.isNotEmpty()) manager.flush()
        val required = gatewayRequiresSignIn(url, statusCode, contentType, location)
        if (required) check(store().edit().putBoolean("expired_${context.key}", true).commit())
        required
    }

    private fun cookieManager(context: GatewayContext): CookieManager =
        ProfileStore.getInstance().getOrCreateProfile(
            store().getString("profile_${context.key}", null) ?: throw GatewaySessionUnavailable()).cookieManager

    /** A fresh profile per login prevents asynchronous clear/relogin races. */
    private fun clearProfile(name: String): CountDownLatch {
        val cleared = CountDownLatch(1)
        val profile = ProfileStore.getInstance().getProfile(name)
        if (profile == null) cleared.countDown()
        else {
            profile.webStorage.deleteAllData()
            profile.cookieManager.removeAllCookies {
                profile.cookieManager.flush()
                cleared.countDown()
            }
        }
        return cleared
    }

    private fun <T> onMain(action: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return action()
        val result = AtomicReference<Result<T>>()
        val ready = CountDownLatch(1)
        main.post { result.set(runCatching(action)); ready.countDown() }
        if (!ready.await(10, TimeUnit.SECONDS)) throw GatewaySessionUnavailable()
        return result.get().getOrThrow()
    }
}

internal fun gatewayRequiresSignIn(url: HttpUrl, statusCode: Int, contentType: String?, location: String?): Boolean {
    val html = contentType?.substringBefore(';')?.trim()?.equals("text/html", ignoreCase = true) == true
    val loginPath = location?.let { url.resolve(it)?.encodedPath }.orEmpty()
    val authRedirect = statusCode in 300..399 &&
        (loginPath.startsWith("/outpost.goauthentik.io/") || loginPath.startsWith("/application/o/authorize") ||
            loginPath.startsWith("/if/flow/") || loginPath == "/login")
    return (statusCode in setOf(401, 403) && html) || authRedirect ||
        (html && (url.encodedPath.contains("/api/") || url.encodedPath.endsWith("/videoplayback")))
}
