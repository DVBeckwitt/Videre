package com.github.dvbeckwitt.videre

import java.io.File
import java.io.IOException

/** Management of extracted thumbnails in the app's device music cache. */
internal class LocalMusicArtworkStorage(private val cache: File) {
    fun status(): Map<String, Any> {
        val files = files()
        return mapOf(
            "usedBytes" to files.sumOf { it.length() },
            "limitBytes" to LIMIT_BYTES,
            "canClear" to files.isNotEmpty(),
        )
    }

    fun clear(): Map<String, Any> {
        var failed = false
        for (file in files()) {
            if (!file.delete() && file.exists()) failed = true
        }
        if (failed) throw IOException("Could not clear extracted device artwork")
        return status()
    }

    private fun files(): List<File> = list(cache.canonicalFile)
        .filter { directory ->
            (directory.name == LEGACY_DIRECTORY || directory.name.matches(COVER_DIRECTORY)) &&
                directory.isDirectory && directory == directory.canonicalFile
        }
        .flatMap { directory ->
            list(directory).filter { it.isFile && it == it.canonicalFile }
        }

    private fun list(directory: File): List<File> = directory.listFiles()?.toList()
        ?: if (!directory.exists()) emptyList() else throw IOException("Could not read artwork storage")

    companion object {
        const val LIMIT_BYTES = 24L * 1024 * 1024
        private const val LEGACY_DIRECTORY = "local_music_covers"
        private val COVER_DIRECTORY = Regex("music-covers-[0-9a-f]{64}")
    }
}
