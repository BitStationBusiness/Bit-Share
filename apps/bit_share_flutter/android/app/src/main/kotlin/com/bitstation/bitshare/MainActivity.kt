package com.bitstation.bitshare

import com.bitstation.bitshare.bridge.BitSharePlugin
import com.bitstation.bitshare.gallery.GalleryPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(BitSharePlugin())
        flutterEngine.plugins.add(GalleryPlugin())
    }
}
