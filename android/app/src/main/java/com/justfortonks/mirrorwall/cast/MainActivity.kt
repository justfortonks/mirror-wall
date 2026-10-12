package com.justfortonks.mirrorwall.cast

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView

/**
 * Lists the Mirror Wall slots on the network; tapping one shares the screen to it. A slot can
 * also be reached by address, for networks that block discovery.
 */
class MainActivity : Activity() {
    private data class Slot(val name: String, val host: String, val port: Int)

    private lateinit var status: TextView
    private lateinit var stopButton: Button
    private lateinit var slotList: LinearLayout
    private lateinit var emptyHint: TextView
    private lateinit var nameField: EditText
    private lateinit var addressField: EditText

    private val slots = sortedMapOf<String, Slot>(String.CASE_INSENSITIVE_ORDER)
    private var nsd: NsdManager? = null
    private var discovering = false
    /** Services found but not yet resolved; NsdManager resolves one at a time. */
    private val toResolve = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    /** Where sharing goes once Android allows it. */
    private var pending: Slot? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildViews()
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 2)
        }
    }

    override fun onStart() {
        super.onStart()
        CastStatus.listener = { showStatus() }
        showStatus()
        startDiscovery()
    }

    override fun onStop() {
        stopDiscovery()
        CastStatus.listener = null
        super.onStop()
    }

    // MARK: Sharing

    private fun share(slot: Slot) {
        Phone.setName(this, nameField.text.toString())
        pending = slot
        val manager = getSystemService(MediaProjectionManager::class.java)
        // Always the whole screen, not a single app: a wall of phones should show what each shows.
        val intent = if (Build.VERSION.SDK_INT >= 34) {
            manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            manager.createScreenCaptureIntent()
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, 1)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        val slot = pending ?: return
        pending = null
        if (requestCode != 1 || resultCode != RESULT_OK || data == null) {
            CastStatus.set(false, "Sharing needs Android's permission each time.")
            return
        }
        startForegroundService(
            Intent(this, CastService::class.java)
                .putExtra(CastService.EXTRA_HOST, slot.host)
                .putExtra(CastService.EXTRA_PORT, slot.port)
                .putExtra(CastService.EXTRA_SLOT, slot.name)
                .putExtra(CastService.EXTRA_RESULT_CODE, resultCode)
                .putExtra(CastService.EXTRA_RESULT_DATA, data),
        )
    }

    private fun stopSharing() {
        startService(Intent(this, CastService::class.java).setAction(CastService.ACTION_STOP))
    }

    private fun shareToTypedAddress() {
        val text = addressField.text.toString().trim()
        if (text.isEmpty()) return
        // "192.168.1.20" means slot 1; "192.168.1.20:7450" names the slot's port.
        val host = text.substringBefore(':')
        val port = text.substringAfter(':', "7350").toIntOrNull() ?: 7350
        share(Slot(text, host, port))
    }

    // MARK: Finding slots

    private fun startDiscovery() {
        if (discovering) return
        val nsd = getSystemService(NsdManager::class.java)
        this.nsd = nsd
        discovering = true
        nsd.discoverServices(CastProtocol.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
    }

    private fun stopDiscovery() {
        if (!discovering) return
        discovering = false
        try {
            nsd?.stopServiceDiscovery(discovery)
        } catch (_: IllegalArgumentException) {
        }
    }

    private val discovery = object : NsdManager.DiscoveryListener {
        override fun onServiceFound(service: NsdServiceInfo) {
            runOnUiThread {
                toResolve.addLast(service)
                resolveNext()
            }
        }

        override fun onServiceLost(service: NsdServiceInfo) {
            runOnUiThread {
                slots.remove(service.serviceName)
                showSlots()
            }
        }

        override fun onDiscoveryStarted(serviceType: String) {}
        override fun onDiscoveryStopped(serviceType: String) {}
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            runOnUiThread { discovering = false }
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
    }

    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (resolving) return
        val service = toResolve.removeFirstOrNull() ?: return
        resolving = true
        nsd?.resolveService(service, object : NsdManager.ResolveListener {
            override fun onServiceResolved(info: NsdServiceInfo) {
                runOnUiThread {
                    info.host?.hostAddress?.let { host ->
                        slots[info.serviceName] = Slot(info.serviceName, host, info.port)
                        showSlots()
                    }
                    resolving = false
                    resolveNext()
                }
            }

            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                runOnUiThread {
                    resolving = false
                    resolveNext()
                }
            }
        })
    }

    // MARK: Views

    private fun showStatus() {
        status.text = CastStatus.text.ifEmpty { "Pick a Mirror Wall slot to share this screen." }
        stopButton.visibility = if (CastStatus.sharing) View.VISIBLE else View.GONE
        slotList.isEnabled = !CastStatus.sharing
        for (index in 0 until slotList.childCount) slotList.getChildAt(index).isEnabled = !CastStatus.sharing
    }

    private fun showSlots() {
        slotList.removeAllViews()
        emptyHint.visibility = if (slots.isEmpty()) View.VISIBLE else View.GONE
        for (slot in slots.values) {
            slotList.addView(Button(this).apply {
                text = slot.name
                isAllCaps = false
                isEnabled = !CastStatus.sharing
                setOnClickListener { share(slot) }
            }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
    }

    private fun buildViews() {
        val pad = (16 * resources.displayMetrics.density).toInt()
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }
        fun heading(text: String) = TextView(this).apply {
            this.text = text
            textSize = 14f
            setPadding(0, pad, 0, pad / 4)
        }

        status = TextView(this).apply { textSize = 18f }
        column.addView(status)
        stopButton = Button(this).apply {
            text = "Stop sharing"
            setOnClickListener { stopSharing() }
        }
        column.addView(stopButton)

        column.addView(heading("Mirror Wall slots on this network"))
        emptyHint = TextView(this).apply {
            text = "Looking… Mirror Wall must be open on a Mac or PC on the same Wi-Fi."
        }
        column.addView(emptyHint)
        slotList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(slotList)

        column.addView(heading("Or connect by address"))
        val addressRow = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        addressField = EditText(this).apply {
            hint = "192.168.1.20"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            imeOptions = EditorInfo.IME_ACTION_GO
            setSingleLine()
            setOnEditorActionListener { _, _, _ -> shareToTypedAddress(); true }
        }
        addressRow.addView(addressField, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        addressRow.addView(Button(this).apply {
            text = "Share"
            setOnClickListener { shareToTypedAddress() }
        })
        column.addView(addressRow)

        column.addView(heading("This phone's name on Mirror Wall"))
        nameField = EditText(this).apply {
            setText(Phone.name(this@MainActivity))
            setSingleLine()
        }
        column.addView(nameField)

        column.addView(Switch(this).apply {
            text = "Keep the screen on while sharing"
            isChecked = Phone.keepsScreenOn(this@MainActivity)
            setPadding(0, pad, 0, 0)
            setOnCheckedChangeListener { _, on -> Phone.setKeepsScreenOn(this@MainActivity, on) }
        })

        column.addView(TextView(this).apply {
            text = "Version ${packageManager.getPackageInfo(packageName, 0).versionName}"
            textSize = 12f
            setPadding(0, pad, 0, 0)
        })

        setContentView(ScrollView(this).apply {
            fitsSystemWindows = true
            addView(column)
        })
        showSlots()
    }
}
