package com.justfortonks.mirrorwall.cast

import android.content.Context
import android.os.Build
import android.provider.Settings
import java.util.UUID

/** How the phone introduces itself to Mirror Wall. */
object Phone {
    private const val PREFS = "phone"

    /** The name chosen in the app, else the phone's own device name, else its model. */
    fun name(context: Context): String {
        val chosen = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("name", null)
        if (!chosen.isNullOrBlank()) return chosen.trim()
        return Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: model()
    }

    fun setName(context: Context, name: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("name", name.trim()).apply()
    }

    /** E.g. "Zebra Technologies HC50". */
    fun model(): String {
        val maker = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        return if (Build.MODEL.startsWith(maker, ignoreCase = true)) Build.MODEL else "$maker ${Build.MODEL}"
    }

    /** A random ID made once per install, so Mirror Wall's allow-list can tell phones apart. */
    fun id(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString("id", null)?.let { return it }
        val id = "android-" + UUID.randomUUID().toString()
        prefs.edit().putString("id", id).apply()
        return id
    }
}
