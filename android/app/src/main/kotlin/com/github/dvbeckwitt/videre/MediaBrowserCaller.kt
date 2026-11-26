package com.github.dvbeckwitt.videre

import android.Manifest.permission.MEDIA_CONTENT_CONTROL
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import java.security.MessageDigest

internal fun isSystemMediaResumptionBrowser(
    packages: PackageManager,
    callingPackage: String,
    uid: Int,
): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
    (uid == Process.SYSTEM_UID ||
        (callingPackage == "com.android.systemui" &&
            packages.getPackagesForUid(uid)?.contains(callingPackage) == true &&
            packages.checkSignatures("android", callingPackage) == PackageManager.SIGNATURE_MATCH))

internal fun isTrustedMediaBrowser(packages: PackageManager, callingPackage: String, uid: Int): Boolean {
    if (uid == Process.myUid() || uid == Process.SYSTEM_UID) return true
    // Android makes an app visible to the service that it binds.
    if (packages.getPackagesForUid(uid)?.contains(callingPackage) != true) return false
    if (packages.checkSignatures("android", callingPackage) == PackageManager.SIGNATURE_MATCH) return true
    if (packages.checkPermission(MEDIA_CONTENT_CONTROL, callingPackage) == PackageManager.PERMISSION_GRANTED) {
        return true
    }
    val signer = mediaHostSigners[callingPackage] ?: return false
    return try {
        packages.hasMediaHostSigner(callingPackage, signer)
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }
}

@Suppress("DEPRECATION")
private fun PackageManager.hasMediaHostSigner(callingPackage: String, signer: ByteArray): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        return hasSigningCertificate(callingPackage, signer, PackageManager.CERT_INPUT_SHA256)
    }
    val signature = getPackageInfo(callingPackage, PackageManager.GET_SIGNATURES)
        .signatures?.singleOrNull() ?: return false
    val fingerprint = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
    return fingerprint.contentEquals(signer)
}

// Production certificate digests from Google's UAMP sample:
// https://github.com/android/uamp/blob/7080a323ae5181cc44d11b319feab81fd4e568d1/common/src/main/res/xml/allowed_media_browser_callers.xml
private val mediaHostSigners = mapOf(
    "com.google.android.projection.gearhead" to "fdb00c43dbde8b51cb312aa81d3b5fa17713adb94b28f598d77f8eb89daceedf",
    "com.google.android.googlequicksearchbox" to "f0fd6c5b410f25cb25c3b53346c8972fae30f8ee7411df910480ad6b2d60db83",
).mapValues { (_, hex) -> hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray() }
