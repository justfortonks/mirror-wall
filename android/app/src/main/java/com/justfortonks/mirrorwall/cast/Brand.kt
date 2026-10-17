package com.justfortonks.mirrorwall.cast

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.TextView
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/** Imprivata brand styling (2026 Brand Style Guide): palette, Barlow, and the hex pattern. */
object Brand {
    val blue = Color.parseColor("#2C3F57")
    val blueRaised = Color.parseColor("#3A5170")
    val red = Color.parseColor("#CC0033")
    val teal = Color.parseColor("#2CD5C4")
    val midBlue = Color.parseColor("#426DA9")
    val sky = Color.parseColor("#4698CB")
    val ice = Color.parseColor("#D2E4F9")
    val page = Color.parseColor("#F4F5F7")
    val line = Color.parseColor("#E3E6EA")
    val muted = Color.parseColor("#6B7A8D")

    private var fonts: Triple<Typeface, Typeface, Typeface>? = null

    /** Barlow regular, semibold and bold, falling back to the system font. */
    private fun fonts(context: Context): Triple<Typeface, Typeface, Typeface> =
        fonts ?: runCatching {
            Triple(
                context.resources.getFont(R.font.barlow_regular),
                context.resources.getFont(R.font.barlow_semibold),
                context.resources.getFont(R.font.barlow_bold),
            )
        }.getOrElse { Triple(Typeface.DEFAULT, Typeface.DEFAULT_BOLD, Typeface.DEFAULT_BOLD) }
            .also { fonts = it }

    fun regular(context: Context) = fonts(context).first
    fun semibold(context: Context) = fonts(context).second
    fun bold(context: Context) = fonts(context).third

    fun dp(context: Context, value: Float) = (value * context.resources.displayMetrics.density).toInt()

    fun rounded(color: Int, radius: Float, stroke: Int? = null, strokeWidth: Int = 0) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = radius
        if (stroke != null) setStroke(strokeWidth, stroke)
    }

    /** A drawable that ripples when tapped, over `content`. */
    fun pressable(content: Drawable, radius: Float, ripple: Int = Color.argb(40, 44, 63, 87)) =
        RippleDrawable(ColorStateList.valueOf(ripple), content, rounded(Color.WHITE, radius))

    /** A filled pill button: red for the main action. */
    fun pill(button: Button, fill: Int = red) {
        val context = button.context
        val radius = dp(context, 26f).toFloat()
        button.background = pressable(rounded(fill, radius), radius, Color.argb(60, 255, 255, 255))
        button.setTextColor(Color.WHITE)
        button.typeface = bold(context)
        button.textSize = 16f
        button.isAllCaps = false
        button.stateListAnimator = null
        button.minHeight = dp(context, 48f)
        val pad = dp(context, 20f)
        button.setPadding(pad, 0, pad, 0)
    }

    /** An outlined button in Imprivata Blue, for secondary actions. */
    fun outline(button: Button, color: Int = blue) {
        val context = button.context
        val radius = dp(context, 22f).toFloat()
        button.background = pressable(rounded(Color.TRANSPARENT, radius, color, dp(context, 1.5f)), radius)
        button.setTextColor(color)
        button.typeface = semibold(context)
        button.textSize = 14f
        button.isAllCaps = false
        button.stateListAnimator = null
        button.minHeight = dp(context, 40f)
        val pad = dp(context, 16f)
        button.setPadding(pad, 0, pad, 0)
    }

    /** A small uppercase section label. */
    fun label(context: Context, text: String) = TextView(context).apply {
        this.text = text.uppercase()
        typeface = bold(context)
        textSize = 12f
        letterSpacing = 0.08f
        setTextColor(muted)
        val pad = dp(context, 16f)
        setPadding(0, pad + pad / 2, 0, pad / 2)
    }

    fun body(context: Context, text: String, size: Float = 15f, color: Int = blue) = TextView(context).apply {
        this.text = text
        typeface = regular(context)
        textSize = size
        setTextColor(color)
        gravity = Gravity.START
    }
}

/**
 * The brand's hex pattern as a corner accent: full hexagons, turning into chevrons toward the
 * bottom, upright as the guide shows them (never rotated), in at most three colors.
 */
class HexPatternView(context: Context, private val colors: IntArray, private val alphaValue: Int = 255) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val path = Path()

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val r = Brand.dp(context, 15f).toFloat()
        val w = sqrt(3f) * r
        val columns = (width / w).toInt() + 1
        val rows = (height / (1.5f * r)).toInt() + 1
        val random = Random(7)
        for (row in 0 until rows) {
            for (column in 0 until columns) {
                // Denser toward the top right, so it reads as a corner accent.
                val fade = 0.8f * (1 - row / (rows * 1.4f)) * (0.55f + column / columns.toFloat() * 0.6f)
                val keep = random.nextFloat() <= fade
                val colorPick = random.nextInt(colors.size)
                val chevronPick = random.nextFloat()
                if (!keep) continue
                val cx = width - ((columns - 1 - column) * w + (if (row % 2 == 1) w / 2 else 0f) + w / 2)
                val cy = row * 1.5f * r + r
                val chevron = row >= rows * 0.45f && chevronPick > 0.35f
                path.reset()
                if (chevron) chevron(cx, cy, r * 0.96f) else hexagon(cx, cy, r * 0.96f)
                paint.color = colors[colorPick]
                paint.alpha = alphaValue
                canvas.drawPath(path, paint)
            }
        }
    }

    private fun hexagon(cx: Float, cy: Float, r: Float) {
        for (k in 0 until 6) {
            val angle = Math.toRadians((60 * k - 90).toDouble())
            val x = cx + r * cos(angle).toFloat()
            val y = cy + r * sin(angle).toFloat()
            if (k == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
    }

    /** A hexagon with a V notch in its top: the guide's chevron. */
    private fun chevron(cx: Float, cy: Float, r: Float) {
        val h = sqrt(3f) / 2 * r
        path.moveTo(cx - h, cy - r / 2)
        path.lineTo(cx, cy)
        path.lineTo(cx + h, cy - r / 2)
        path.lineTo(cx + h, cy + r / 2)
        path.lineTo(cx, cy + r)
        path.lineTo(cx - h, cy + r / 2)
        path.close()
    }
}
