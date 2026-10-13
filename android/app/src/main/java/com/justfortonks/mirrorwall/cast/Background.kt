package com.justfortonks.mirrorwall.cast

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings

/**
 * Whether Android lets the app run in the background without battery limits. Without it, battery
 * saving can pause or end sharing while the phone is idle. Intune can also allow it for every
 * phone (on Zebra phones through the Zebra OEMConfig app), so nobody has to answer the prompt.
 */
object Background {
    fun isUnrestricted(context: Context): Boolean =
        context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)

    /** Android's prompt to allow it. */
    @SuppressLint("BatteryLife") // a company app that has to keep sharing while the phone is idle
    fun requestIntent(context: Context): Intent =
        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
}
