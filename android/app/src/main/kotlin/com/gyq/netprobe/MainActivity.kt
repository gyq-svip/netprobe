package com.gyq.netprobe

import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var pendingPermResult: MethodChannel.Result? = null
    private lateinit var wifiBridge: WifiBridge
    private lateinit var probeBridge: ProbeBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        wifiBridge = WifiBridge(this)
        probeBridge = ProbeBridge(this)
        wifiBridge.register(messenger)
        probeBridge.register(messenger)
    }

    /** 由 [WifiBridge] 调用，异步等待系统权限弹窗结果 */
    fun requestAppPermissions(perms: Array<String>, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(perms.associateWith { true })
            return
        }
        pendingPermResult?.success(mapOf<String, Boolean>())
        pendingPermResult = result
        requestPermissions(perms, REQ_PERMS)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERMS) return
        val pending = pendingPermResult ?: return
        pendingPermResult = null
        pending.success(
            permissions.indices.associate { i ->
                permissions[i] to (grantResults.getOrNull(i) == PackageManager.PERMISSION_GRANTED)
            }
        )
    }

    override fun onDestroy() {
        if (::probeBridge.isInitialized) probeBridge.dispose()
        super.onDestroy()
    }

    companion object {
        const val REQ_PERMS = 0x9E01
    }
}
