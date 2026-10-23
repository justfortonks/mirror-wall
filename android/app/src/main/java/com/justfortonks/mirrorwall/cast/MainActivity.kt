package com.justfortonks.mirrorwall.cast

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import com.journeyapps.barcodescanner.ScanIntentResult
import com.journeyapps.barcodescanner.ScanOptions
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/**
 * Lists the Mirror Wall slots on the network; tapping one shares the screen to it. A slot can
 * also be reached by address, or by scanning the QR code Mirror Wall shows (Connect with QR
 * Code…), for networks that block discovery.
 */
class MainActivity : Activity() {
    private data class Slot(val name: String, val host: String, val port: Int)

    private lateinit var headline: TextView
    private lateinit var status: TextView
    private lateinit var stopButton: Button
    private lateinit var slotList: LinearLayout
    private lateinit var emptyHint: TextView
    private lateinit var nameField: EditText
    private lateinit var addressField: EditText
    private lateinit var backgroundRow: LinearLayout

    private val slots = sortedMapOf<String, Slot>(String.CASE_INSENSITIVE_ORDER)
    private var nsd: NsdManager? = null
    private var discovering = false
    /** Services found but not yet resolved; NsdManager resolves one at a time. */
    private val toResolve = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    /** Where sharing goes once Android allows it. */
    private var pending: Slot? = null
    /** Asked this time the app opened to run in the background, so it isn't asked at every share. */
    private var askedBackground = false
    /** A scanned link being tried address by address; a newer one replaces it. */
    private var reaching: ConnectLink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildViews()
        savedInstanceState?.let { state ->
            val host = state.getString("pendingHost")
            if (host != null) pending = Slot(state.getString("pendingName") ?: host, host, state.getInt("pendingPort"))
            askedBackground = state.getBoolean("askedBackground")
            state.getString("typedAddress")?.let { addressField.setText(it) }
            state.getString("typedName")?.let { nameField.setText(it) }
        }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 2)
        }
        // Opened by the camera app scanning Mirror Wall's code (first open only; a rotation keeps pending).
        if (savedInstanceState == null) intent?.dataString?.let { openLink(it) }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent?.dataString?.let { openLink(it) }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        pending?.let {
            outState.putString("pendingHost", it.host)
            outState.putString("pendingName", it.name)
            outState.putInt("pendingPort", it.port)
        }
        outState.putBoolean("askedBackground", askedBackground)
        outState.putString("typedAddress", addressField.text.toString())
        outState.putString("typedName", nameField.text.toString())
    }

    override fun onStart() {
        super.onStart()
        CastStatus.listener = { showStatus() }
        showStatus()
        showBackground()
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
        // Battery saving can end sharing on an idle phone; ask once before the first share.
        if (!askedBackground && !Background.isUnrestricted(this)) {
            askedBackground = true
            AppLog.write("Asking to run in the background")
            @Suppress("DEPRECATION")
            startActivityForResult(Background.requestIntent(this), 3)
            return
        }
        askToCapture()
    }

    private fun askToCapture() {
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
        if (requestCode == 3) {
            AppLog.write("Run in the background: ${if (Background.isUnrestricted(this)) "allowed" else "not allowed"}")
            showBackground()
            if (pending != null) askToCapture()
            return
        }
        if (requestCode == 4) {
            val scanned = ScanIntentResult.parseActivityResult(resultCode, data).contents
            if (scanned != null) openLink(scanned) else AppLog.write("QR scan cancelled")
            return
        }
        if (requestCode != 1) return
        val slot = pending ?: run {
            CastStatus.set(false, "Choose a receiver and tap Share again.")
            return
        }
        pending = null
        if (resultCode != RESULT_OK || data == null) {
            AppLog.write("Screen sharing not allowed on the phone")
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

    // MARK: QR code and links

    private fun scanCode() {
        if (CastStatus.sharing) return
        AppLog.write("Scanning a QR code")
        val options = ScanOptions()
            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setPrompt("Point the camera at the code in Mirror Wall")
            .setBeepEnabled(false)
            .setOrientationLocked(false)
        @Suppress("DEPRECATION")
        startActivityForResult(options.createScanIntent(this), 4)
    }

    /** Text from a scan or a mirrorwall:// link: share to the slot it names. */
    private fun openLink(text: String) {
        val link = ConnectLink.parse(text)
        if (link == null) {
            AppLog.write("Not a Mirror Wall code: ${text.take(80)}")
            CastStatus.set(false, "That isn't a Mirror Wall code.")
            return
        }
        AppLog.write("Code for ${link.name}: ${link.hosts.joinToString()} port ${link.port}")
        if (CastStatus.sharing) {
            CastStatus.set(true, "Stop sharing first, then scan again.")
            return
        }
        if (link.hosts.size == 1) {
            share(Slot(link.name, link.hosts[0], link.port))
            return
        }
        // The computer listed every address it has; use the first that answers. A guest
        // network usually blocks the Wi-Fi one and lets the VPN one through, or the other way.
        reaching = link
        CastStatus.set(false, "Reaching ${link.name}…")
        thread(name = "reach") {
            val host = link.hosts.firstOrNull { reaching === link && answers(it, link.port) }
            runOnUiThread {
                if (reaching !== link) return@runOnUiThread
                reaching = null
                if (host != null) {
                    AppLog.write("${link.name} answered at $host")
                    share(Slot(link.name, host, link.port))
                } else {
                    AppLog.write("${link.name} didn't answer at any address")
                    CastStatus.set(false, "Couldn't reach ${link.name}. Is this phone on the same Wi-Fi or VPN as the computer?")
                }
            }
        }
    }

    /** A quick knock on the slot's port; Mirror Wall drops a connection that never says hello. */
    private fun answers(host: String, port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress(host, port), 2000) }
        true
    } catch (_: Exception) {
        false
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

    // MARK: Background and log

    private fun showBackground() {
        backgroundRow.visibility = if (Background.isUnrestricted(this)) View.GONE else View.VISIBLE
    }

    private fun shareLog() {
        AppLog.write("Sharing the log")
        val send = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_SUBJECT, "Mirror Wall Cast log from ${Phone.name(this)}")
            .putExtra(Intent.EXTRA_STREAM, LogProvider.URI)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(Intent.createChooser(send, "Share the log"))
    }

    private fun showLog() {
        val text = TextView(this).apply {
            text = AppLog.tail(300).ifEmpty { "Nothing logged yet." }
            textSize = 11f
            setTextIsSelectable(true)
            typeface = android.graphics.Typeface.MONOSPACE
            val pad = (12 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad)
        }
        val scroll = ScrollView(this).apply { addView(text) }
        AlertDialog.Builder(this)
            .setTitle("Log")
            .setView(scroll)
            .setPositiveButton("Close", null)
            .setNeutralButton("Share") { _, _ -> shareLog() }
            .show()
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    // MARK: Views

    private fun showStatus() {
        headline.text = if (CastStatus.sharing) "Sharing this screen" else "Pick a slot"
        status.text = CastStatus.text.ifEmpty { "Mirror Wall slots on this Wi-Fi appear below." }
        stopButton.visibility = if (CastStatus.sharing) View.VISIBLE else View.GONE
        slotList.isEnabled = !CastStatus.sharing
        for (index in 0 until slotList.childCount) {
            val card = slotList.getChildAt(index)
            card.isEnabled = !CastStatus.sharing
            card.alpha = if (CastStatus.sharing) 0.5f else 1f
        }
    }

    private fun showSlots() {
        slotList.removeAllViews()
        emptyHint.visibility = if (slots.isEmpty()) View.VISIBLE else View.GONE
        for (slot in slots.values) {
            slotList.addView(slotCard(slot), LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply {
                bottomMargin = Brand.dp(this@MainActivity, 10f)
            })
        }
        showStatus()
    }

    /** A white card per slot: a teal dot (slots only show while free), its name, tap to share. */
    private fun slotCard(slot: Slot): View {
        val radius = Brand.dp(this, 14f).toFloat()
        val pad = Brand.dp(this, 16f)
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = Brand.pressable(Brand.card(this@MainActivity, radius), radius)
            setPadding(pad, pad, pad, pad)
            isClickable = true
            isEnabled = !CastStatus.sharing
            setOnClickListener { share(slot) }
            addView(View(this@MainActivity).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(Brand.lamp)
                }
            }, LinearLayout.LayoutParams(Brand.dp(this@MainActivity, 10f), Brand.dp(this@MainActivity, 10f)).apply {
                marginEnd = Brand.dp(this@MainActivity, 14f)
            })
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                addView(Brand.body(this@MainActivity, slot.name, 16f).apply { typeface = Brand.semibold(this@MainActivity) })
                addView(Brand.body(this@MainActivity, "Tap to share this screen", 13f, Brand.inkMuted(this@MainActivity)))
            }, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
            addView(Brand.body(this@MainActivity, "›", 24f, Brand.lampText(this@MainActivity)))
        }
    }

    private fun field(hintText: String? = null) = EditText(this).apply {
        hint = hintText
        typeface = Brand.regular(this@MainActivity)
        textSize = 16f
        setTextColor(Brand.ink(this@MainActivity))
        setHintTextColor(Brand.inkFaint(this@MainActivity))
        val radius = Brand.dp(this@MainActivity, 12f).toFloat()
        background = Brand.rounded(Brand.surfaceRaised(this@MainActivity), radius, Brand.line(this@MainActivity), Brand.dp(this@MainActivity, 1f))
        val pad = Brand.dp(this@MainActivity, 14f)
        setPadding(pad, pad, pad, pad)
        setSingleLine()
    }

    private fun buildViews() {
        val pad = Brand.dp(this, 16f)

        // Header: the lamp, with ink on it; the wordmark in Fraunces as the eyebrow.
        val header = FrameLayout(this).apply { setBackgroundColor(Brand.lamp) }
        val headerColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad + pad / 4, pad, pad + pad / 4, pad + pad / 2)
        }
        headerColumn.addView(TextView(this).apply {
            text = "Mirror Wall Cast"
            typeface = Brand.display(this@MainActivity)
            textSize = 15f
            setTextColor(Brand.onLamp)
        })
        headline = TextView(this).apply {
            typeface = Brand.bold(this@MainActivity)
            textSize = 28f
            setTextColor(Brand.onLamp)
            setPadding(0, pad / 4, 0, 0)
        }
        headerColumn.addView(headline)
        status = Brand.body(this, "", 15f, Color.argb(200, 18, 16, 21))
        headerColumn.addView(status)
        stopButton = Button(this).apply {
            text = "Stop sharing"
            setOnClickListener { stopSharing() }
            Brand.pill(this, Brand.onLamp, Brand.lamp)
        }
        headerColumn.addView(stopButton, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { topMargin = pad })
        header.addView(headerColumn, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad / 2, pad, pad * 2)
        }

        backgroundRow = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val radius = Brand.dp(this@MainActivity, 14f).toFloat()
            background = Brand.card(this@MainActivity, radius)
            setPadding(pad, pad, pad, pad)
            addView(Brand.body(this@MainActivity, "Battery saving can stop sharing while the phone is idle.", 14f))
            addView(Button(this@MainActivity).apply {
                text = "Allow running in the background"
                Brand.outline(this)
                setOnClickListener {
                    @Suppress("DEPRECATION")
                    startActivityForResult(Background.requestIntent(this@MainActivity), 3)
                }
            }, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { topMargin = pad / 2 })
        }
        column.addView(backgroundRow, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = pad })

        column.addView(Brand.label(this, "Slots on this network"))
        emptyHint = Brand.body(this, "Looking… Mirror Wall must be open on a Mac or PC on the same Wi-Fi.", 14f, Brand.inkMuted(this))
        column.addView(emptyHint)
        slotList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(slotList)

        column.addView(Brand.label(this, "Or scan the code in Mirror Wall"))
        column.addView(Button(this).apply {
            text = "Scan QR Code"
            Brand.pill(this)
            setOnClickListener { scanCode() }
        }, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        column.addView(Brand.body(this, "Mirror Wall › Connect with QR Code… shows it. Works where this list stays empty: guest Wi-Fi, or a VPN both share.", 13f, Brand.inkMuted(this)).apply {
            setPadding(0, pad / 2, 0, 0)
        })

        column.addView(Brand.label(this, "Or connect by address"))
        val addressRow = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        addressField = field("192.168.1.20").apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            imeOptions = EditorInfo.IME_ACTION_GO
            setOnEditorActionListener { _, _, _ -> shareToTypedAddress(); true }
        }
        addressRow.addView(addressField, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        addressRow.addView(Button(this).apply {
            text = "Share"
            Brand.pill(this)
            setOnClickListener { shareToTypedAddress() }
        }, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { marginStart = pad / 2 })
        column.addView(addressRow)

        column.addView(Brand.label(this, "This phone's name on Mirror Wall"))
        nameField = field().apply { setText(Phone.name(this@MainActivity)) }
        column.addView(nameField)

        column.addView(Switch(this).apply {
            text = "Keep the screen on while sharing"
            typeface = Brand.regular(this@MainActivity)
            textSize = 15f
            setTextColor(Brand.ink(this@MainActivity))
            val states = arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf())
            thumbTintList = ColorStateList(states, intArrayOf(Brand.lamp, Brand.surfaceRaised(this@MainActivity)))
            trackTintList = ColorStateList(states, intArrayOf(Color.argb(110, 255, 176, 48), Brand.line(this@MainActivity)))
            isChecked = Phone.keepsScreenOn(this@MainActivity)
            setPadding(0, pad, 0, 0)
            setOnCheckedChangeListener { _, on -> Phone.setKeepsScreenOn(this@MainActivity, on) }
        })

        column.addView(Brand.label(this, "Troubleshooting"))
        val logRow = LinearLayout(this)
        logRow.addView(Button(this).apply {
            text = "Show Log"
            Brand.outline(this)
            setOnClickListener { showLog() }
        })
        logRow.addView(Button(this).apply {
            text = "Share Log"
            Brand.outline(this)
            setOnClickListener { shareLog() }
        }, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { marginStart = pad / 2 })
        column.addView(logRow)

        column.addView(Brand.body(this, "Version ${packageManager.getPackageInfo(packageName, 0).versionName}", 12f, Brand.inkMuted(this)).apply {
            setPadding(0, pad, 0, 0)
        })

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Brand.surface(this@MainActivity))
            addView(column)
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Brand.surface(this@MainActivity))
            addView(header, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            addView(scroll, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        }
        // Edge to edge: the lamp header runs up behind the status bar; the list clears the
        // navigation bar and the keyboard.
        val headerTop = headerColumn.paddingTop
        val columnBottom = column.paddingBottom
        root.setOnApplyWindowInsetsListener { _, insets ->
            val top: Int
            val bottom: Int
            if (Build.VERSION.SDK_INT >= 30) {
                top = insets.getInsets(WindowInsets.Type.statusBars()).top
                bottom = insets.getInsets(WindowInsets.Type.navigationBars() or WindowInsets.Type.ime()).bottom
            } else {
                @Suppress("DEPRECATION")
                top = insets.systemWindowInsetTop
                @Suppress("DEPRECATION")
                bottom = insets.systemWindowInsetBottom
            }
            headerColumn.setPadding(headerColumn.paddingLeft, headerTop + top, headerColumn.paddingRight, headerColumn.paddingBottom)
            column.setPadding(column.paddingLeft, column.paddingTop, column.paddingRight, columnBottom + bottom)
            insets
        }
        setContentView(root)
        @Suppress("DEPRECATION")
        window.statusBarColor = Brand.lamp
        if (Build.VERSION.SDK_INT >= 30) {
            // Dark status bar icons on the lamp header; navigation icons follow the page's appearance.
            val light = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                (if (Brand.isDark(this)) 0 else WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
            window.insetsController?.setSystemBarsAppearance(
                light,
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
            )
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = window.decorView.systemUiVisibility or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        }
        showSlots()
    }
}
