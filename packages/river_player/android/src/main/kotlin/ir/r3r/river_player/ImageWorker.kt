package ir.r3r.river_player

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import androidx.media3.datasource.DataSourceInputStream
import androidx.media3.datasource.DataSpec
import androidx.work.Data
import androidx.work.WorkerParameters
import androidx.work.Worker
import java.io.File
import java.io.FileOutputStream
import java.lang.Exception

class ImageWorker(
    context: Context,
    params: WorkerParameters
) : Worker(context, params) {
    override fun doWork(): Result {
        return try {
            val imageUrl = inputData.getString(RiverPlayerPlugin.URL_PARAMETER)
                ?: return Result.failure()
            val bitmap: Bitmap? = if (DataSourceUtils.isHTTP(Uri.parse(imageUrl))) {
                getBitmapFromExternalURL(imageUrl)
            } else {
                getBitmapFromInternalURL(imageUrl)
            }
            val fileName = imageUrl.hashCode().toString() + IMAGE_EXTENSION
            val file = File(applicationContext.cacheDir, fileName)
            if (bitmap == null) {
                return Result.failure()
            }
            val written = FileOutputStream(file).use { out ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            }
            if (!written) return Result.failure()
            val data =
                Data.Builder().putString(RiverPlayerPlugin.FILE_PATH_PARAMETER, file.absolutePath).build()
            Result.success(data)
        } catch (e: Exception) {
            e.printStackTrace()
            Result.failure()
        }
    }

    private fun getBitmapFromExternalURL(src: String): Bitmap? {
        return try {
            // Artwork must obey the same SOCKS policy as the media request,
            // including redirects, refused proxies and settings changes.
            val factory = DataSourceUtils.getDataSourceFactory(
                DataSourceUtils.getUserAgent(null), null, src)
            val dataSpec = DataSpec(Uri.parse(src))
            val options = BitmapFactory.Options()
            options.inJustDecodeBounds = true
            DataSourceInputStream(factory.createDataSource(), dataSpec).use {
                BitmapFactory.decodeStream(it, null, options)
            }
            options.inSampleSize = calculateBitmapInSampleSize(
                options
            )
            options.inJustDecodeBounds = false
            DataSourceInputStream(factory.createDataSource(), dataSpec).use {
                BitmapFactory.decodeStream(it, null, options)
            }
        } catch (exception: Exception) {
            Log.e(TAG, "Failed to load notification artwork")
            null
        }
    }

    private fun calculateBitmapInSampleSize(
        options: BitmapFactory.Options
    ): Int {
        val height = options.outHeight
        val width = options.outWidth
        var inSampleSize = 1
        if (height > DEFAULT_NOTIFICATION_IMAGE_SIZE_PX
            || width > DEFAULT_NOTIFICATION_IMAGE_SIZE_PX
        ) {
            val halfHeight = height / 2
            val halfWidth = width / 2
            while (halfHeight / inSampleSize >= DEFAULT_NOTIFICATION_IMAGE_SIZE_PX
                && halfWidth / inSampleSize >= DEFAULT_NOTIFICATION_IMAGE_SIZE_PX
            ) {
                inSampleSize *= 2
            }
        }
        return inSampleSize
    }

    private fun getBitmapFromInternalURL(src: String): Bitmap? {
        return try {
            BitmapFactory.decodeFile(src)
        } catch (exception: Exception) {
            Log.e(TAG, "Failed to get bitmap from internal url: $src")
            null
        }
    }

    companion object {
        private const val TAG = "ImageWorker"
        private const val IMAGE_EXTENSION = ".png"
        private const val DEFAULT_NOTIFICATION_IMAGE_SIZE_PX = 256
    }
}
