package com.justfortonks.mirrorwall.cast

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns

/**
 * Hands the log to the app the user shares it with (email, Teams, Drive…), read-only and only for
 * that share.
 */
class LogProvider : ContentProvider() {
    companion object {
        const val AUTHORITY = "com.justfortonks.mirrorwall.cast.log"
        val URI: Uri = Uri.parse("content://$AUTHORITY/MirrorWallCast-log.txt")
    }

    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val context = context ?: throw IllegalStateException("No context")
        return ParcelFileDescriptor.open(AppLog.snapshot(context), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri) = "text/plain"

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val size = context?.let { AppLog.snapshot(it).length() } ?: 0L
        return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply {
            addRow(arrayOf<Any>("MirrorWallCast-log.txt", size))
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
