package com.justfortonks.mirrorwall.cast

import android.app.Application

class CastApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AppLog.start(this)
    }
}
