package io.github.dearzl.mirrorbridge

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.StatFs
import android.content.Intent
import android.provider.Settings

class MainActivity : FlutterActivity() {
    private var native: CameraNative? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        native = CameraNative(this, flutterEngine.dartExecutor.binaryMessenger, flutterEngine.renderer)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mirrorbridge.ui/storage").setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("ui_rebuild", MODE_PRIVATE)
            when (call.method) {
                "storageInfo" -> {
                    val storage = StatFs(filesDir.absolutePath)
                    result.success(mapOf("freeBytes" to storage.availableBytes, "totalBytes" to storage.totalBytes))
                }
                "freeBytes" -> result.success(StatFs(filesDir.absolutePath).availableBytes)
                "load" -> result.success(prefs.getString(call.arguments as String, ""))
                "save" -> { prefs.edit().putString(call.argument<String>("key"), call.argument<String>("value")).apply(); result.success(null) }
                "wifi" -> { startActivity(Intent(Settings.ACTION_WIFI_SETTINGS)); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (native?.onActivityResult(requestCode, resultCode, data) != true) super.onActivityResult(requestCode, resultCode, data)
    }
    override fun onDestroy() { native?.recordLifecycle("onDestroy"); native?.dispose(); super.onDestroy() }
    override fun onPause() { native?.recordLifecycle("onPause"); android.util.Log.i("MirrorBridgeLifecycle", "onPause pid=${android.os.Process.myPid()}"); super.onPause() }
    override fun onStop() { native?.recordLifecycle("onStop"); android.util.Log.i("MirrorBridgeLifecycle", "onStop pid=${android.os.Process.myPid()}"); super.onStop() }
    override fun onResume() { super.onResume(); native?.recordLifecycle("onResume"); android.util.Log.i("MirrorBridgeLifecycle", "onResume pid=${android.os.Process.myPid()}") }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (native?.onRequestPermissionsResult(requestCode, grantResults) != true) super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
