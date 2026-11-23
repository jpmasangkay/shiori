package com.example.manga_reader

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

class WebViewActivity : Activity() {
    private lateinit var webView: WebView
    private lateinit var progressBar: ProgressBar
    private lateinit var titleView: TextView
    private var currentUrl: String = ""

    private fun isAllowedWebUrl(raw: String?): Boolean {
        if (raw.isNullOrBlank()) return false
        val scheme = try {
            Uri.parse(raw).scheme?.lowercase()
        } catch (_: Throwable) {
            null
        }
        return scheme == "http" || scheme == "https"
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val rawUrl = intent.getStringExtra(EXTRA_URL) ?: ""
        val targetUrl = if (isAllowedWebUrl(rawUrl)) rawUrl else ""
        val initialTitle = intent.getStringExtra(EXTRA_TITLE) ?: "Browser"
        val customUserAgent = intent.getStringExtra(EXTRA_USER_AGENT)
        currentUrl = targetUrl

        val rootLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#0F1016"))
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Color.parseColor("#171922"))
            setPadding(dpToPx(8), dpToPx(8), dpToPx(8), dpToPx(8))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dpToPx(56)
            )
        }

        val closeBtn = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setBackgroundColor(Color.TRANSPARENT)
            setColorFilter(Color.WHITE)
            contentDescription = "Close browser"
            layoutParams = LinearLayout.LayoutParams(dpToPx(48), dpToPx(48))
            setOnClickListener { finish() }
        }
        toolbar.addView(closeBtn)

        titleView = TextView(this).apply {
            text = initialTitle
            setTextColor(Color.WHITE)
            textSize = 16f
            isSingleLine = true
            setPadding(dpToPx(12), 0, dpToPx(8), 0)
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        toolbar.addView(titleView)

        val refreshBtn = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_rotate)
            setBackgroundColor(Color.TRANSPARENT)
            setColorFilter(Color.WHITE)
            contentDescription = "Reload page"
            layoutParams = LinearLayout.LayoutParams(dpToPx(48), dpToPx(48))
            setOnClickListener { webView.reload() }
        }
        toolbar.addView(refreshBtn)

        val openExternalBtn = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_compass)
            setBackgroundColor(Color.TRANSPARENT)
            setColorFilter(Color.WHITE)
            contentDescription = "Open in external browser"
            layoutParams = LinearLayout.LayoutParams(dpToPx(48), dpToPx(48))
            setOnClickListener {
                val urlToOpen = webView.url ?: currentUrl
                if (isAllowedWebUrl(urlToOpen)) {
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(urlToOpen)))
                    } catch (_: Exception) {}
                }
            }
        }
        toolbar.addView(openExternalBtn)

        rootLayout.addView(toolbar)

        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dpToPx(3)
            )
        }
        rootLayout.addView(progressBar)

        webView = WebView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
            setBackgroundColor(Color.parseColor("#0F1016"))
        }

        val settings = webView.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = true
        settings.cacheMode = WebSettings.LOAD_DEFAULT
        // Security hardening: disable local file & content URI access
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            settings.safeBrowsingEnabled = true
        }

        val defaultUa = if (!customUserAgent.isNullOrBlank()) {
            customUserAgent
        } else {
            try {
                WebSettings.getDefaultUserAgent(this)
            } catch (_: Throwable) {
                "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Mobile Safari/537.36"
            }
        }
        settings.userAgentString = defaultUa

        val cookieManager = CookieManager.getInstance()
        cookieManager.setAcceptCookie(true)
        cookieManager.setAcceptThirdPartyCookies(webView, true)

        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                progressBar.progress = newProgress
                progressBar.visibility = if (newProgress in 1..99) View.VISIBLE else View.GONE
            }

            override fun onReceivedTitle(view: WebView?, title: String?) {
                if (!title.isNullOrEmpty()) {
                    titleView.text = title
                }
            }
        }

        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                val urlStr = request?.url?.toString()
                return !isAllowedWebUrl(urlStr)
            }

            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                super.onPageStarted(view, url, favicon)
                progressBar.visibility = View.VISIBLE
                if (url != null && isAllowedWebUrl(url)) currentUrl = url
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                progressBar.visibility = View.GONE
                try {
                    CookieManager.getInstance().flush()
                } catch (_: Throwable) {}
            }
        }

        rootLayout.addView(webView)
        setContentView(rootLayout)

        if (targetUrl.isNotEmpty()) {
            webView.loadUrl(targetUrl)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (this::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
        } else {
            @Suppress("DEPRECATION")
            super.onBackPressed()
        }
    }

    override fun onDestroy() {
        try {
            CookieManager.getInstance().flush()
            if (this::webView.isInitialized) {
                webView.stopLoading()
                webView.destroy()
            }
        } catch (_: Throwable) {}
        super.onDestroy()
    }

    private fun dpToPx(dp: Int): Int {
        val density = resources.displayMetrics.density
        return (dp * density).toInt()
    }

    companion object {
        const val EXTRA_URL = "extra_url"
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_USER_AGENT = "extra_user_agent"
    }
}
