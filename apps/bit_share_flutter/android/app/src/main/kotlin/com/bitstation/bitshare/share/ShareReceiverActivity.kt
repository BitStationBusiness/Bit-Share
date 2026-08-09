package com.bitstation.bitshare.share

import com.bitstation.bitshare.bridge.BitSharePlugin
import com.bitstation.bitshare.gallery.GalleryPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine

class ShareReceiverActivity : FlutterActivity() {
    override fun getInitialRoute(): String = "/share"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(BitSharePlugin())
        flutterEngine.plugins.add(GalleryPlugin())
    }
}
