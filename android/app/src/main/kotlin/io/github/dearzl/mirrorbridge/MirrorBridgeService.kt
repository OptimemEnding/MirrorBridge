package io.github.dearzl.mirrorbridge

import android.app.*
import android.content.Intent
import android.os.*
import android.net.wifi.WifiManager

class MirrorBridgeService: Service() {
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("mirrorbridge", "相机同步", NotificationManager.IMPORTANCE_LOW))
        val launch = packageManager.getLaunchIntentForPackage(packageName)!!
        val pending = PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(this, "mirrorbridge").setSmallIcon(android.R.drawable.stat_sys_upload).setContentTitle("镜桥相机同步")
            .setContentText("正在保持相机连接，断开相机后结束").setContentIntent(pending).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(901, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(901, notification)
        wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MirrorBridge:connection").apply { acquire() }
        @Suppress("DEPRECATION")
        wifi = applicationContext.getSystemService(WIFI_SERVICE).let { it as WifiManager }.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "MirrorBridge:Wifi").apply { acquire() }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_NOT_STICKY
    override fun onBind(intent: Intent?) = null
    override fun onDestroy() { if (wake?.isHeld == true) wake?.release(); if (wifi?.isHeld == true) wifi?.release(); super.onDestroy() }
}
