package io.github.dearzl.mirrorbridge

import android.app.Activity
import android.app.PendingIntent
import android.content.*
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.hardware.usb.*
import android.net.*
import android.os.*
import io.flutter.plugin.common.*
import java.io.*
import java.net.Inet4Address
import java.net.NetworkInterface
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class CameraNative(private val activity: Activity, messenger: BinaryMessenger, private val textures: io.flutter.view.TextureRegistry) {
    private var gpu: LiveRenderer? = null
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val imageExecutor = Executors.newSingleThreadExecutor()
    private val imageEditor by lazy { ImageEditor(activity) }
    private val usbManager = activity.getSystemService(UsbManager::class.java)
    @Volatile private var usb: UsbPtpTransport? = null
    @Volatile private var cancelled = AtomicBoolean(false)
    private var usbId: String? = null
    private var usbApplicationPropertyFallback = false
    private var usbLiveOpcode = 0x9428
    private var events: EventChannel.EventSink? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var permissionReceiver: BroadcastReceiver? = null
    private val permissionAction = activity.packageName + ".USB_PERMISSION"
    private val library = PhoneMediaLibrary(activity, messenger, ::log)
    private val root: File get() = library.root
    fun onActivityResult(request: Int, code: Int, data: Intent?) = library.onActivityResult(request, code, data)
    fun onRequestPermissionsResult(request: Int, results: IntArray) = library.onRequestPermissionsResult(request, results)
    private val diagnostics = File(activity.filesDir, "camera-diagnostics.log")
    init {
        EventChannel(messenger, "mirrorbridge/native_events").setStreamHandler(object: EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { events = sink }
            override fun onCancel(arguments: Any?) { events = null }
        })
        MethodChannel(messenger, "mirrorbridge/native").setMethodCallHandler { call, result ->
            if (library.handle(call, result)) return@setMethodCallHandler
            when (call.method) {
                "screenRotation" -> result.success(activity.windowManager.defaultDisplay.rotation)
                "connectionTrace" -> { log("PTP ${call.argument<String>("message")?.take(2048)}"); result.success(null) }
                "discoverNames" -> discoverNames(result)
                "gpuStart" -> try { gpu?.close(); gpu = LiveRenderer(activity, textures.createSurfaceTexture(), ::emit); result.success(gpu!!.id) } catch(e: Throwable) { fail(result,e) }
                "gpuSubmit" -> {
                    val renderer=gpu
                    if(renderer==null) result.error("GPU_CLOSED","监看渲染未启动",null)
                    else renderer.submit(call.argument<ByteArray>("jpeg")!!) { error ->
                        handler.post { if(error==null) result.success(true) else fail(result,error) }
                    }
                }
                "gpuOptions" -> { gpu?.options = (call.arguments as? Map<String, Any?>) ?: emptyMap(); result.success(null) }
                "gpuLut" -> { val renderer = gpu; if(renderer==null) result.error("GPU_CLOSED","监看渲染未启动",null) else renderer.setLut(call.argument<String>("name")) { error -> handler.post { if(error==null) result.success(null) else fail(result,error) } } }
                "monitorAwake" -> {
                    if(call.argument<Boolean>("active")==true) activity.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else if(gpu==null) activity.window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                "gpuStop" -> {
                    val owner=call.argument<Number>("textureId")?.toLong()
                    if(owner==null || owner==gpu?.id) { gpu?.close(); gpu=null }
                    result.success(null)
                }
                "usbPermission" -> requestUsb(call.argument<String>("deviceId")!!, result)
                "service" -> {
                    log("connection service active=${call.argument<Boolean>("active") == true}")
                    if (call.argument<Boolean>("active") == true) activity.startForegroundService(Intent(activity, MirrorBridgeService::class.java)) else activity.stopService(Intent(activity, MirrorBridgeService::class.java))
                    result.success(null)
                }
                "usbCancel" -> { cancelled.set(true); usb?.cancel(); result.success(null) }
                else -> (if (call.method in listOf("effect", "nativeSelfTest")) imageExecutor else executor).execute {
                    try { val value = execute(call); handler.post { result.success(value) } } catch (e: Throwable) { handler.post { fail(result, e) } }
                }
            }
        }
    }
    @Suppress("DEPRECATION")
    private fun discoverNames(result: MethodChannel.Result) {
        val manager = activity.getSystemService(android.net.nsd.NsdManager::class.java)
        val names = java.util.concurrent.ConcurrentHashMap<String, String>()
        val listeners = mutableListOf<android.net.nsd.NsdManager.DiscoveryListener>()
        var finished = false
        for (kind in listOf("_ptp._tcp.", "_nikon._tcp.")) {
            val listener = object : android.net.nsd.NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(t: String) {}
                override fun onDiscoveryStopped(t: String) {}
                override fun onStartDiscoveryFailed(t: String, code: Int) {}
                override fun onStopDiscoveryFailed(t: String, code: Int) {}
                override fun onServiceLost(info: android.net.nsd.NsdServiceInfo) {}
                override fun onServiceFound(info: android.net.nsd.NsdServiceInfo) {
                    if (finished) return
                    manager.resolveService(info, object : android.net.nsd.NsdManager.ResolveListener {
                        override fun onResolveFailed(i: android.net.nsd.NsdServiceInfo, code: Int) {}
                        override fun onServiceResolved(i: android.net.nsd.NsdServiceInfo) {
                            i.host?.hostAddress?.let { names[it] = i.serviceName }
                        }
                    })
                }
            }
            listeners.add(listener)
            runCatching { manager.discoverServices(kind, android.net.nsd.NsdManager.PROTOCOL_DNS_SD, listener) }
        }
        handler.postDelayed({
            finished = true
            listeners.forEach { runCatching { manager.stopServiceDiscovery(it) } }
            result.success(names.toMap())
        }, 1800)
    }
    private fun fail(result: MethodChannel.Result, error: Throwable) {
        val e = error
        log("ERROR ${e.javaClass.name}: ${e.message}")
        if (e is PtpResponseException) {
            result.error("PTP_RESPONSE", e.message, mapOf("operation" to e.operation, "response" to e.response))
        } else result.error("CAMERA_NATIVE", e.message ?: e.javaClass.simpleName, null)
    }
    @Synchronized private fun log(message: String) {
        if (diagnostics.length() > 2 * 1024 * 1024) diagnostics.writeText("")
        diagnostics.appendText("${java.time.Instant.now()} $message\n")
        android.util.Log.i("MirrorBridgeNative", message)
    }
    fun recordLifecycle(state: String) { log("lifecycle $state pid=${android.os.Process.myPid()}") }
    private fun emit(event: Map<String, Any?>) { handler.post { events?.success(event) } }
    private fun device(id: String) = usbManager.deviceList.values.firstOrNull { it.deviceName == id } ?: error("USB 相机已断开")
    private fun ptpDevice(d: UsbDevice) = d.vendorId == 1200 && (0 until d.interfaceCount).any { d.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_STILL_IMAGE }
    private fun requestUsb(id: String, result: MethodChannel.Result) {
        if (pendingPermission != null) { result.error("USB_PERMISSION_BUSY", "请先处理 USB 授权窗口", null); return }
        try {
            val d = device(id)
            if (usbManager.hasPermission(d)) { result.success(true); return }
            pendingPermission = result
            val receiver = object: BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action != permissionAction) return
                    pendingPermission?.success(intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
                    pendingPermission = null; runCatching { activity.unregisterReceiver(this) }; permissionReceiver = null
                }
            }
            permissionReceiver = receiver
            if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(receiver, IntentFilter(permissionAction), Context.RECEIVER_NOT_EXPORTED) else activity.registerReceiver(receiver, IntentFilter(permissionAction))
            usbManager.requestPermission(d, PendingIntent.getBroadcast(activity, 0, Intent(permissionAction).setPackage(activity.packageName), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE))
        } catch (e: Throwable) { pendingPermission = null; fail(result, e) }
    }
    private fun params(call: MethodCall) = (call.argument<List<Number>>("params") ?: emptyList()).map { it.toInt() }.toIntArray()
    private fun execute(call: MethodCall): Any? = when (call.method) {
        "nativeInfo" -> componentInfo()
        "directories" -> mapOf("media" to root.absolutePath, "cache" to activity.cacheDir.absolutePath, "freeBytes" to StatFs(root.absolutePath).availableBytes)
        "network" -> network(call.argument<String>("host"), call.argument<Boolean>("bind") == true)
        "unbind" -> activity.getSystemService(ConnectivityManager::class.java).bindProcessToNetwork(null)
        "usbList" -> usbManager.deviceList.values.filter(::ptpDevice).map { mapOf("deviceId" to it.deviceName, "name" to (it.productName ?: "Nikon USB"), "vendorId" to it.vendorId, "productId" to it.productId, "permission" to usbManager.hasPermission(it)) }
        "usbOpen" -> {
            closeUsb()
            val d = device(call.argument<String>("deviceId")!!)
            check(ptpDevice(d)) { "当前仅接入 Nikon PTP 相机" }
            check(usbManager.hasPermission(d)) { "请先授予 USB 访问权限" }
            for (attempt in 0..1) {
                val c = usbManager.openDevice(d) ?: error("无法打开 USB 设备")
                val client = UsbPtpTransport(d, c) { code, eventParams ->
                    emit(mapOf("type" to "cameraEvent", "code" to code, "params" to eventParams.toList()))
                }
                try {
                    if (client.open()) { usb = client; usbId = d.deviceName; break }
                    client.close()
                } catch (e: Throwable) {
                    runCatching { client.close() }
                    if (attempt == 1) throw e
                }
                Thread.sleep(700)
            }
            check(usb != null) { "PTP 会话恢复失败，请重新插拔相机" }
            cancelled.set(false); usbApplicationPropertyFallback = false; usbLiveOpcode = 0x9428
            log("USB/PTP connected ${d.productName} id=${d.deviceName}")
            mapOf("make" to (d.manufacturerName ?: "Nikon"), "model" to (d.productName ?: "Nikon USB"),
                "serial" to runCatching { d.serialNumber }.getOrNull().orEmpty(), "vendorId" to d.vendorId)
        }
        "usbData" -> {
            val code = call.argument<Number>("code")!!.toInt()
            val bytes = (usb ?: error("USB 未连接")).data(code, params(call), call.argument<Number>("timeout")?.toInt() ?: 15000)
            log("USB DATA op=0x${code.toString(16)} bytes=${bytes.size} head=${bytes.take(96).joinToString("") { "%02x".format(it) }}")
            bytes
        }
        "usbCommand" -> (usb ?: error("USB 未连接")).command(call.argument<Number>("code")!!.toInt(), params(call))
        "usbWriteProperty" -> { (usb ?: error("USB 未连接")).writeProperty(call.argument<Number>("code")!!.toInt(), call.argument<ByteArray>("data")!!); null }
        "usbDownload" -> usbDownload(call)
        "usbLiveStart" -> { startUsbLiveView(); true }
        "usbApplicationMode" -> { setUsbApplicationMode(call.argument<Number>("mode")!!.toInt()); true }
        "usbLiveFrame" -> readUsbLiveFrame()
        "usbClose" -> { closeUsb(); true }
        "effect" -> library.imageTransaction {
            val source = call.argument<String>("path")!!
            val sourceFile = library.materialize(source)
            val sourceExif = library.exif(call.argument<String>("exifPath") ?: source)
            try { imageEditor.render(sourceFile.path, call.argument<String>("lut"), call.argument<Number>("intensity")?.toFloat() ?: 1f,
                call.argument<String>("template"), call.argument<Number>("border")?.toFloat() ?: .5f,
                call.argument<Boolean>("details") != false, call.argument<Number>("maxDimension")?.toInt(), sourceExif,
                call.argument<Map<String, Map<String, Any?>>>("captionStyles") ?: emptyMap()) } finally { if (source.startsWith("content://")) sourceFile.delete() }
        }
        "diagnostics" -> { val out = File(activity.cacheDir, "MirrorBridge-diagnostics.txt"); out.writeText("MirrorBridge components\n${componentInfo()}\n${diagnostics.takeIf { it.exists() }?.readText() ?: ""}\nUSB/PTP trace\n${usb?.traceText().orEmpty()}\n"); out.absolutePath }
        "nativeSelfTest" -> selfTest()
        else -> error("未知原生操作 ${call.method}")
    }
    private fun closeUsb() { usb?.let { runCatching { it.close() } }; usb = null; usbId = null }
    private fun usbDownload(call: MethodCall): Long {
        val client = usb ?: error("USB 未连接")
        val quiet = call.argument<Boolean>("quiet") == true
        val handle = call.argument<Number>("handle")!!.toInt(); val expected = call.argument<Number>("bytes")!!.toLong()
        val file = File(call.argument<String>("path")!!); var offset = call.argument<Number>("offset")?.toLong() ?: 0
        require(expected > 0 && offset in 0..expected && (!file.exists() || file.length() == offset)) { "下载长度或恢复偏移无效" }
        cancelled.set(false)
        var partial64 = call.argument<Boolean>("partial64") == true
        var whole = call.argument<Boolean>("whole") == true
        require(!whole || expected <= 0xffffffffL - UsbPtpCodec.HEADER_SIZE) {
            "相机未提供 64 位分块下载，文件超过 PTP 整文件容器上限"
        }
        while (offset < expected) {
            check(!cancelled.get()) { "传输已取消" }
            val before = offset
            val count = if (whole) expected else minOf(4L * 1024 * 1024, expected - offset)
            val operation = if (whole) 0x1009 else if (partial64) 0x9431 else 0x101b
            val operationParams = when (operation) {
                0x9431 -> intArrayOf(handle, offset.toInt(), (offset ushr 32).toInt(), count.toInt(), 0)
                0x101b -> intArrayOf(handle, offset.toInt(), count.toInt())
                else -> intArrayOf(handle)
            }
            try {
                val got = FileOutputStream(file, !whole && offset > 0).use { out ->
                    client.download(operation, operationParams, out) { received ->
                        if (cancelled.get()) client.cancel()
                        if (!quiet) emit(mapOf("type" to "progress", "done" to before + received, "total" to expected))
                    }
                }
                check(got == count) { "相机返回的分块长度无效：$got / $count" }
                offset += got
            } catch (e: PtpResponseException) {
                if (file.exists()) RandomAccessFile(file, "rw").use { it.setLength(before) }
                if (e.response !in listOf(0x2005, 0x2006) || whole) throw e
                if (partial64 && expected <= 0xffffffffL) { partial64 = false; continue }
                if (partial64) {
                    throw IllegalStateException("相机拒绝 64 位分块下载，无法传输超过 4 GiB 的文件", e)
                }
                whole = true
                offset = 0
                if (file.exists()) RandomAccessFile(file, "rw").use { it.setLength(0) }
            }
        }
        check(file.length() == expected && offset == expected) { "下载大小校验失败" }
        log("USB/PTP download complete handle=$handle bytes=$expected"); return offset
    }

    private fun setUsbApplicationMode(mode: Int) {
        val client = usb ?: error("USB 未连接")
        if (!usbApplicationPropertyFallback) {
            val response = client.command(0x9435, intArrayOf(mode))
            if (response == 0x2001) return
            if (response != 0x2005) throw PtpResponseException(0x9435, response)
            usbApplicationPropertyFallback = true
        }
        client.writeProperty(0xd1f0, byteArrayOf(mode.toByte()))
    }

    private fun startUsbLiveView() {
        val client = usb ?: error("USB 未连接")
        val response = client.command(0x9201, intArrayOf())
        if (response != 0x2001) throw PtpResponseException(0x9201, response)
        val clock = android.os.SystemClock.elapsedRealtime()
        while (android.os.SystemClock.elapsedRealtime() - clock < 5_000) {
            val ready = client.command(0x90c8, intArrayOf(), 2_000)
            if (ready == 0x2001 || ready == 0x2005) return
            if (ready != 0x2019) throw PtpResponseException(0x90c8, ready)
            Thread.sleep(150)
        }
        error("相机持续忙碌，请检查当前拍摄模式")
    }

    private fun readUsbLiveFrame(): ByteArray {
        val client = usb ?: error("USB 未连接")
        return try {
            client.data(usbLiveOpcode, intArrayOf(), 5_000)
        } catch (error: PtpResponseException) {
            if (error.response in listOf(0x2005, 0x2006) && usbLiveOpcode == 0x9428) {
                usbLiveOpcode = 0x9203
                client.data(usbLiveOpcode, intArrayOf(), 5_000)
            } else throw error
        }
    }
    private fun network(host: String?, bind: Boolean): Map<String, Any?> {
        val cm = activity.getSystemService(ConnectivityManager::class.java)
        val networks = cm.allNetworks.filter { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true }
        val destination = host?.let { runCatching { java.net.InetAddress.getByName(it) }.getOrNull() }
        val routed = if (destination == null) networks else networks.filter { n ->
            cm.getLinkProperties(n)?.routes?.any { !it.isDefaultRoute && it.matches(destination) } == true
        }
        val chosen = cm.boundNetworkForProcess?.takeIf { it in routed }
            ?: cm.activeNetwork?.takeIf { it in routed } ?: routed.firstOrNull()
        if ((!bind || (host != null && chosen == null)) && cm.boundNetworkForProcess != null) {
            check(cm.bindProcessToNetwork(null)) { "无法恢复内网路由" }
        }
        if (bind && chosen != null && chosen != cm.boundNetworkForProcess) {
            check(cm.bindProcessToNetwork(chosen)) { "无法绑定相机 Wi-Fi" }
        }
        log("network host=$host chosen=$chosen bound=${cm.boundNetworkForProcess} wifiNetworks=${networks.size}")
        val addresses = mutableSetOf<String>(); val candidates = mutableSetOf<String>()
        val interfaces = mutableListOf<Map<String, Any>>()
        NetworkInterface.getNetworkInterfaces()?.toList()?.filter { it.isUp && !it.isLoopback }?.forEach { iface ->
            iface.interfaceAddresses.filter { it.address is Inet4Address && it.address.isSiteLocalAddress }.forEach {
                addresses.add(it.address.hostAddress!!)
                interfaces.add(mapOf("address" to it.address.hostAddress!!, "prefix" to it.networkPrefixLength.toInt(), "name" to iface.name))
            }
        }
        networks.forEach { n ->
            cm.getLinkProperties(n)?.let { link ->
                link.linkAddresses.filter { it.address is Inet4Address }.forEach {
                    interfaces.add(mapOf("address" to it.address.hostAddress!!, "prefix" to it.prefixLength))
                }
                link.routes.mapNotNull { it.gateway }.filterIsInstance<Inet4Address>()
                    .filter { !it.isAnyLocalAddress }.mapNotNull { it.hostAddress }.forEach(candidates::add)
            }
        }
        if (host != null) candidates.add(host)
        // Keep the advertised client name short and limited to camera-safe ASCII.
        val deviceName = runCatching { android.provider.Settings.Global.getString(activity.contentResolver, "device_name") }.getOrNull()
        val rawName = listOf(deviceName, Build.MODEL, Build.DEVICE, "MirrorBridge").first { !it.isNullOrBlank() }!!
        val clientName = rawName.replace(Regex("[^A-Za-z0-9_-]"), "").ifBlank { "MirrorBridge" }.take(16)
        return mapOf("addresses" to addresses.toList(), "interfaces" to interfaces, "candidates" to candidates.toList(), "wifi" to networks.isNotEmpty(), "bound" to (cm.boundNetworkForProcess != null), "clientName" to clientName)
    }
    private fun componentInfo(): Map<String, Any> = mapOf(
        "component" to "MirrorBridge Android platform",
        "usbPtp" to mapOf(
            "containerCodec" to true,
            "streamDownload" to true,
            "partial64" to true,
            "events" to true,
        ),
        "imageEditor" to imageEditor.capabilities(),
        "gpu" to mapOf("gles" to 3, "cubeLut" to true, "zebra" to true, "peaking" to true),
    )

    private fun selfTest(): Map<String, Any?> {
        val info = componentInfo(); val bitmap = Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888)
        for (y in 0..63) for (x in 0..95) bitmap.setPixel(x, y, android.graphics.Color.rgb(x * 255 / 95, y * 255 / 63, 100))
        val input = File(activity.cacheDir, "native-test-source.jpg"); input.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it) }; bitmap.recycle()
        val outputs = mutableListOf<Map<String, Any>>()
        for (t in ImageEditor.TEMPLATES) {
            val path = imageEditor.render(input.path, null, 1f, t, 1f, true, 256,
                mapOf("Make" to "Nikon", "Model" to "Test", "ExposureTime" to "1/250", "FNumber" to "2.8"))
            val b = BitmapFactory.decodeFile(path) ?: error("模板 $t 输出不可解码")
            check(b.width > 0 && b.height > 0); outputs.add(mapOf("template" to t, "width" to b.width, "height" to b.height, "bytes" to File(path).length())); b.recycle()
        }
        val luts = activity.assets.list("luts")!!.filter { it.endsWith(".cube") }
        for (name in luts) {
            val path = imageEditor.render(input.path, name.removeSuffix(".cube").replace("%20", " "), .75f, null, 1f, true, 256, emptyMap())
            val b = BitmapFactory.decodeFile(path) ?: error("LUT $name 输出不可解码"); check(b.width == 96 && b.height == 64); b.recycle()
        }
        val openSession = UsbPtpCodec.command(0x1002, 1, intArrayOf(1))
        val getStorageIds = UsbPtpCodec.command(0x1004, 2, intArrayOf())
        val result = mapOf(
            "native" to info,
            "watermarks" to outputs,
            "lutCount" to luts.size,
            "protocol" to mapOf(
                "openSession" to openSession.joinToString("") { "%02x".format(it) },
                "getStorageIds" to getStorageIds.joinToString("") { "%02x".format(it) },
            ),
            "success" to true,
        )
        File(activity.filesDir, "native-self-test.json").writeText(org.json.JSONObject(result).toString(2)); return result
    }
    fun dispose() { library.dispose(); gpu?.close(); gpu=null; permissionReceiver?.let { runCatching { activity.unregisterReceiver(it) } }; pendingPermission?.error("CLOSED", "页面已关闭", null); pendingPermission = null; cancelled.set(true); executor.execute { closeUsb() }; executor.shutdown(); imageExecutor.shutdown() }
}
