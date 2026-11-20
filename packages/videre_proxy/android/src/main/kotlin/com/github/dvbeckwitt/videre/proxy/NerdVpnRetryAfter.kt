package com.github.dvbeckwitt.videre.proxy

import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

private const val obsoleteHttpDate = "EEEE, dd-MMM-yy HH:mm:ss 'GMT'"
private val httpDateFormats = listOf("EEE, dd MMM yyyy HH:mm:ss 'GMT'", obsoleteHttpDate, "EEE MMM d HH:mm:ss yyyy")

/** Accept seconds and HTTP dates. Round up so requests never resume before a future deadline. */
internal fun nerdVpnRetryAfterSeconds(header: String?, nowMillis: Long = System.currentTimeMillis()): Long? {
    val value = header?.trim()?.takeIf { it.isNotEmpty() && it.length <= 64 } ?: return null
    value.toLongOrNull()?.let { return it.takeIf { seconds -> seconds >= 0 } }

    val gmt = TimeZone.getTimeZone("GMT")
    val deadline = httpDateFormats.firstNotNullOfOrNull { pattern ->
        val format = SimpleDateFormat(pattern, Locale.US).apply {
            timeZone = gmt
            isLenient = false
            if (pattern == obsoleteHttpDate) {
                // Two-digit years more than 50 years ahead describe the previous century.
                set2DigitYearStart(Calendar.getInstance(gmt, Locale.US).apply {
                    timeInMillis = nowMillis
                    add(Calendar.YEAR, -50)
                }.time)
            }
        }
        val position = ParsePosition(0)
        format.parse(value, position)?.time?.takeIf { position.index == value.length }
    } ?: return null
    if (deadline <= nowMillis) return 0
    val millis = runCatching { Math.subtractExact(deadline, nowMillis) }.getOrNull() ?: return null
    return millis / 1000 + if (millis % 1000 == 0L) 0 else 1
}
