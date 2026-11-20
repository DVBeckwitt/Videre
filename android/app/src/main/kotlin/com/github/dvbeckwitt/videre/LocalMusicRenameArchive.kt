package com.github.dvbeckwitt.videre

import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/** Download references can be updated even after the originating music source is forgotten. */
internal class LocalMusicRenameArchive(file: File) {
    private val storage = AtomicFile(file)

    fun read(): List<Map<String, String>> {
        val array = try {
            JSONArray(storage.readFully().toString(Charsets.UTF_8))
        } catch (_: FileNotFoundException) {
            return emptyList()
        }
        return (0 until array.length()).map { position ->
            val event = array.getJSONObject(position)
            mapOf("id" to event.getString("id"), "oldUri" to event.getString("oldUri"),
                "newUri" to event.getString("newUri"))
        }
    }

    fun retain(events: List<Map<String, String>>) {
        if (events.isNotEmpty()) write((read() + events).distinctBy { it.getValue("id") })
    }

    fun remove(id: String) {
        val remaining = read().filterNot { it["id"] == id }
        write(remaining)
    }

    private fun write(events: List<Map<String, String>>) {
        if (events.isEmpty()) {
            storage.delete()
            return
        }
        val bytes = JSONArray(events.map { JSONObject(it) }).toString().toByteArray(Charsets.UTF_8)
        val output = storage.startWrite()
        try {
            output.write(bytes)
            storage.finishWrite(output)
        } catch (failure: Exception) {
            storage.failWrite(output)
            throw failure
        }
    }
}
