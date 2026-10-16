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

/**
 * Lists the Mirror Wall slots on the network; tapping one shares the screen to it. A slot can
 * also be reached by address, for networks that block discovery.
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
        val slot = pending ?: return
        pending = null
        if (requestCode != 1 || resultCode != RESULT_OK || data == null) {
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
            background = Brand.pressable(Brand.rounded(Color.WHITE, radius, Brand.line, Brand.dp(this@MainActivity, 1f)), radius)
            setPadding(pad, pad, pad, pad)
            isClickable = true
            isEnabled = !CastStatus.sharing
            setOnClickListener { share(slot) }
            addView(View(this@MainActivity).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(Brand.teal)
                }
            }, LinearLayout.LayoutParams(Brand.dp(this@MainActivity, 10f), Brand.dp(this@MainActivity, 10f)).apply {
                marginEnd = Brand.dp(this@MainActivity, 14f)
            })
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                addView(Brand.body(this@MainActivity, slot.name, 16f).apply { typeface = Brand.semibold(this@MainActivity) })
                addView(Brand.body(this@MainActivity, "Tap to share this screen", 13f, Brand.muted))
            }, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
            addView(Brand.body(this@MainActivity, "›", 24f, Brand.red))
        }
    }

    private fun field(hintText: String? = null) = EditText(this).apply {
        hint = hintText
        typeface = Brand.regular(this@MainActivity)
        textSize = 16f
        setTextColor(Brand.blue)
        setHintTextColor(Brand.muted)
        val radius = Brand.dp(this@MainActivity, 12f).toFloat()
        background = Brand.rounded(Color.WHITE, radius, Brand.line, Brand.dp(this@MainActivity, 1f))
        val pad = Brand.dp(this@MainActivity, 14f)
        setPadding(pad, pad, pad, pad)
        setSingleLine()
    }

    private fun buildViews() {
        val pad = Brand.dp(this, 16f)

        // Header: Imprivata Blue, a teal eyebrow, the hex pattern in the corner.
        val header = FrameLayout(this).apply { setBackgroundColor(Brand.blue) }
        header.addView(
            HexPatternView(this, intArrayOf(Brand.blueRaised, Brand.midBlue, Brand.teal), 210),
            FrameLayout.LayoutParams(Brand.dp(this, 170f), Brand.dp(this, 140f), Gravity.TOP or Gravity.END),
        )
        val headerColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad + pad / 4, pad, pad + pad / 4, pad + pad / 2)
        }
        headerColumn.addView(TextView(this).apply {
            text = "MIRROR WALL CAST"
            typeface = Brand.bold(this@MainActivity)
            textSize = 12f
            letterSpacing = 0.08f
            setTextColor(Brand.teal)
        })
        headline = TextView(this).apply {
            typeface = Brand.bold(this@MainActivity)
            textSize = 28f
            setTextColor(Color.WHITE)
            setPadding(0, pad / 4, 0, 0)
        }
        headerColumn.addView(headline)
        status = Brand.body(this, "", 15f, Brand.ice)
        headerColumn.addView(status)
        stopButton = Button(this).apply {
            text = "Stop sharing"
            setOnClickListener { stopSharing() }
            Brand.pill(this)
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
            background = Brand.rounded(Color.WHITE, radius, Brand.line, Brand.dp(this@MainActivity, 1f))
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
        emptyHint = Brand.body(this, "Looking… Mirror Wall must be open on a Mac or PC on the same Wi-Fi.", 14f, Brand.muted)
        column.addView(emptyHint)
        slotList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(slotList)

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
            setTextColor(Brand.blue)
            val states = arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf())
            thumbTintList = ColorStateList(states, intArrayOf(Brand.teal, Color.WHITE))
            trackTintList = ColorStateList(states, intArrayOf(Color.argb(110, 44, 213, 196), Brand.line))
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

        column.addView(Brand.body(this, "Version ${packageManager.getPackageInfo(packageName, 0).versionName}", 12f, Brand.muted).apply {
            setPadding(0, pad, 0, 0)
        })

        val scroll = ScrollView(this).apply {
            setBackgroundColor(Brand.page)
            addView(column)
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Brand.page)
            addView(header, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            addView(scroll, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        }
        // Edge to edge: the Blue header runs up behind the status bar; the list clears the
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
        window.statusBarColor = Brand.blue
        if (Build.VERSION.SDK_INT >= 30) {
            // Light status bar icons on the Blue header, dark navigation icons on the light page.
            window.insetsController?.setSystemBarsAppearance(
                WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
            )
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR.inv()
        }
        showSlots()
    }
}
