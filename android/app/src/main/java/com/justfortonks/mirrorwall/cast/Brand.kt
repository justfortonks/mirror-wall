package com.justfortonks.mirrorwall.cast

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.widget.Button
import android.widget.TextView

/**
 * Mirror Wall's look on the phone (the design system's "stagecraft" direction). Colors come from
 * `res/values/colors.xml` and `res/values-night/colors.xml`, so the app follows the system's light
 * or dark appearance; Inter for UI, Fraunces for the wordmark. Keep this file and the Mac's
 * `Brand.swift` in step when a value changes.
 */
object Brand {
    // Identity, the same in both appearances
    const val lamp = 0xFFFFB030.toInt()
    const val gel = 0xFFFF3D8F.toInt()
    /** Signal: links, addresses, section labels. */
    const val signal = 0xFF27E0FF.toInt()
    /** Night: the header, both appearances (it's a piece of the Stage). */
    const val night = 0xFF0B0D16.toInt()
    const val onNight = 0xFFEEF0FF.toInt()
    const val onNightMuted = 0xFFA9AFD6.toInt()
    const val hot = 0xFFE5484D.toInt()
    /** Ink on lamp (the only text color that reads on it). */
    const val onLamp = 0xFF121015.toInt()

    // Surfaces and ink, resolved on the current appearance
    fun surface(context: Context) = context.getColor(R.color.surface)
    fun surfaceRaised(context: Context) = context.getColor(R.color.surface_raised)
    fun surfaceSunken(context: Context) = context.getColor(R.color.surface_sunken)
    fun ink(context: Context) = context.getColor(R.color.ink)
    fun inkMuted(context: Context) = context.getColor(R.color.ink_muted)
    fun inkFaint(context: Context) = context.getColor(R.color.ink_faint)
    fun line(context: Context) = context.getColor(R.color.line)
    fun lampText(context: Context) = context.getColor(R.color.lamp_text)
    fun signalText(context: Context) = context.getColor(R.color.signal_text)
    fun standby(context: Context) = context.getColor(R.color.standby)
    fun isDark(context: Context) =
        context.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK ==
            android.content.res.Configuration.UI_MODE_NIGHT_YES

    private var fonts: Triple<Typeface, Typeface, Typeface>? = null
    private var displayFont: Typeface? = null

    /** Inter regular, semibold and bold, falling back to the system font. */
    private fun fonts(context: Context): Triple<Typeface, Typeface, Typeface> =
        fonts ?: runCatching {
            Triple(
                context.resources.getFont(R.font.inter_regular),
                context.resources.getFont(R.font.inter_semibold),
                context.resources.getFont(R.font.inter_bold),
            )
        }.getOrElse { Triple(Typeface.DEFAULT, Typeface.DEFAULT_BOLD, Typeface.DEFAULT_BOLD) }
            .also { fonts = it }

    fun regular(context: Context) = fonts(context).first
    fun semibold(context: Context) = fonts(context).second
    fun bold(context: Context) = fonts(context).third

    /** Fraunces Bold, for the wordmark only. */
    fun display(context: Context): Typeface = displayFont ?: runCatching {
        context.resources.getFont(R.font.fraunces_bold)
    }.getOrElse { Typeface.create(Typeface.SERIF, Typeface.BOLD) }.also { displayFont = it }

    fun dp(context: Context, value: Float) = (value * context.resources.displayMetrics.density).toInt()

    fun rounded(color: Int, radius: Float, stroke: Int? = null, strokeWidth: Int = 0) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = radius
        if (stroke != null) setStroke(strokeWidth, stroke)
    }

    /** A drawable that ripples when tapped, over `content`. */
    fun pressable(content: Drawable, radius: Float, ripple: Int = Color.argb(40, 18, 16, 21)) =
        RippleDrawable(ColorStateList.valueOf(ripple), content, rounded(Color.WHITE, radius))

    /** A card: raised surface with a hairline, 14dp corners. */
    fun card(context: Context, radius: Float = dp(context, 14f).toFloat()) =
        rounded(surfaceRaised(context), radius, line(context), dp(context, 1f))

    /** A filled pill button: lamp with ink text, for the main action. */
    fun pill(button: Button, fill: Int = lamp, text: Int = onLamp) {
        val context = button.context
        val radius = dp(context, 26f).toFloat()
        button.background = pressable(rounded(fill, radius), radius, Color.argb(50, 255, 255, 255))
        button.setTextColor(text)
        button.typeface = bold(context)
        button.textSize = 16f
        button.isAllCaps = false
        button.stateListAnimator = null
        button.minHeight = dp(context, 48f)
        val pad = dp(context, 20f)
        button.setPadding(pad, 0, pad, 0)
    }

    /** An outlined button in ink, for secondary actions. */
    fun outline(button: Button, color: Int? = null) {
        val context = button.context
        val tint = color ?: ink(context)
        val radius = dp(context, 22f).toFloat()
        button.background = pressable(rounded(Color.TRANSPARENT, radius, color ?: line(context), dp(context, 1.5f)), radius)
        button.setTextColor(tint)
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
        textSize = 11f
        letterSpacing = 0.1f
        typeface = Typeface.MONOSPACE
        setTextColor(signalText(context))
        val pad = dp(context, 16f)
        setPadding(0, pad + pad / 2, 0, pad / 2)
    }

    fun body(context: Context, text: String, size: Float = 15f, color: Int? = null) = TextView(context).apply {
        this.text = text
        typeface = regular(context)
        textSize = size
        setTextColor(color ?: ink(context))
        gravity = Gravity.START
    }
}
