package com.justfortonks.mirrorwall.cast

import java.net.URLDecoder

/**
 * A link from Mirror Wall's "Connect with QR Code…" window:
 * `mirrorwall://connect?name=Mirror%20Wall%201&port=7350&host=192.168.1.20&host=100.101.1.2`.
 *
 * It names one slot and every address the computer has, best first (Wi-Fi, then Tailscale, then
 * other VPNs). The app tries them in order and shares to the first that answers, so it works where
 * discovery doesn't: guest Wi-Fi that keeps devices apart, or a VPN both ends share.
 *
 * Parsed by hand (not android.net.Uri) so it can be unit-tested; the Mac's `ConnectLink` is the
 * other half, and the two stay in step: unknown items are ignored, no port means slot 1.
 */
data class ConnectLink(val name: String, val port: Int, val hosts: List<String>) {
    companion object {
        const val SCHEME = "mirrorwall"
        const val ACTION = "connect"
        const val DEFAULT_PORT = 7350

        /** Null if the text isn't a connect link. */
        fun parse(text: String?): ConnectLink? {
            val trimmed = text?.trim() ?: return null
            val schemeEnd = trimmed.indexOf("://")
            if (schemeEnd < 0 || !trimmed.substring(0, schemeEnd).equals(SCHEME, ignoreCase = true)) return null
            val rest = trimmed.substring(schemeEnd + 3)
            val queryStart = rest.indexOfAny(charArrayOf('?', '/'))
            val action = if (queryStart < 0) rest else rest.substring(0, queryStart)
            if (!action.equals(ACTION, ignoreCase = true)) return null
            val query = rest.substringAfter('?', "").substringBefore('#')
            var name = ""
            var port = DEFAULT_PORT
            val hosts = ArrayList<String>()
            for (pair in query.split('&')) {
                if (pair.isEmpty()) continue
                val key = pair.substringBefore('=')
                val value = decode(pair.substringAfter('=', "")).trim()
                if (value.isEmpty()) continue
                when (key) {
                    "name" -> name = value
                    "port" -> port = value.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
                    "host" -> if (value !in hosts) hosts.add(value)
                }
            }
            if (hosts.isEmpty()) return null
            return ConnectLink(name.ifEmpty { hosts[0] }, port, hosts)
        }

        private fun decode(value: String): String = try {
            URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")
        } catch (_: IllegalArgumentException) {
            value
        }
    }
}
