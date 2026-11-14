package com.github.dvbeckwitt.videre.proxy

import java.net.URI
import java.net.URLDecoder

/** Only the exact callback for this isolated browser attempt can return a token. */
fun invidiousTokenFromCallback(value: String, nonce: String): String? = runCatching {
    if (value.length > 262144 || !Regex("^[A-Za-z0-9-]+$").matches(nonce)) return@runCatching null
    val received = URI(value)
    if (received.scheme != "videre-gateway" || received.rawAuthority != "callback" ||
        received.rawPath != "/$nonce" || received.rawFragment != null) return@runCatching null
    val query = received.rawQuery?.split('&')?.map {
        val parts = it.split('=', limit = 2)
        URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts.getOrElse(1) { "" }, "UTF-8")
    } ?: return@runCatching null
    query.filter { it.first == "token" }.singleOrNull()?.second
        ?.takeIf { it.isNotBlank() && it.length <= 65536 }
}.getOrNull()
