package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MusicAndroidSettingsLauncherTest {
    @Test fun selectsAppSpecificSettingsActions() {
        val notifications = MusicAndroidSettingsPage.NOTIFICATIONS
        assertEquals("android.settings.APP_NOTIFICATION_SETTINGS", notifications.action)
        assertEquals(26, notifications.minSdk)
        assertFalse(notifications.usesPackageUri)

        val battery = MusicAndroidSettingsPage.BATTERY
        assertEquals("android.settings.VIEW_ADVANCED_POWER_USAGE_DETAIL", battery.action)
        assertEquals(31, battery.minSdk)
        assertTrue(battery.usesPackageUri)

        val appDetails = MusicAndroidSettingsPage.APP_DETAILS
        assertEquals("android.settings.APPLICATION_DETAILS_SETTINGS", appDetails.action)
        assertEquals(9, appDetails.minSdk)
        assertTrue(appDetails.usesPackageUri)
    }

    @Test fun onlyAttemptsTheRequestedPageOnAnEligibleApiLevel() {
        for (page in MusicAndroidSettingsPage.entries) {
            val attempts = mutableListOf<MusicAndroidSettingsPage>()
            val launch: (MusicAndroidSettingsPage) -> Boolean = {
                attempts.add(it)
                true
            }

            assertFalse(tryOpenMusicAndroidSettings(page, page.minSdk - 1, launch))
            assertTrue(attempts.isEmpty())
            assertTrue(tryOpenMusicAndroidSettings(page, page.minSdk, launch))
            assertEquals(listOf(page), attempts)
        }
    }

    @Test fun reportsMissingOrBlockedSettingsScreensAsUnavailable() {
        for (page in MusicAndroidSettingsPage.entries) {
            assertFalse(tryOpenMusicAndroidSettings(page, page.minSdk) { false })
            assertFalse(tryOpenMusicAndroidSettings(page, page.minSdk) {
                throw SecurityException("Settings activity requires permission")
            })
        }
    }
}
