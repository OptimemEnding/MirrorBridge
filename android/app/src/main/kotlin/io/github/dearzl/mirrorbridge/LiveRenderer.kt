package io.github.dearzl.mirrorbridge

import android.content.Context
import android.opengl.*
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

/** Decodes camera JPEG frames and renders them into a Flutter-owned GLES texture. */
class LiveRenderer(private val context: Context, private val entry: TextureRegistry.SurfaceTextureEntry, private val event: (Map<String, Any?>) -> Unit) {
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var closed = false
    @Volatile private var busy = false
    @Volatile var options: Map<String, Any?> = emptyMap()
    val id get() = entry.id()
    private var display = EGL14.EGL_NO_DISPLAY
    private var eglContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface = EGL14.EGL_NO_SURFACE
    private var surface: Surface? = null
    private var program=0
    private var texture=0
    private var lutTexture=0
    private var lut: CubeLut?=null
    private var droppedFrames=0
    private var frames=0
    private var width=0
    private var height=0
    private var lastScopeMs=0L
    private val scopeHistogram = RgbHistogram()
    private val scopeWave = IntArray(160 * 64)
    private var scopeRow = IntArray(0)
    private val decoder = LiveJpegDecoder()
    private val uniforms = HashMap<String, Int>()
    private fun location(name: String) = uniforms.getOrPut(name) { GLES30.glGetUniformLocation(program, name) }
    private var timingStartNs = System.nanoTime()
    private var timingFrames = 0
    private var decodeNs = 0L
    private var uploadNs = 0L
    private var presentNs = 0L
    private var maxFrameNs = 0L
    fun submit(jpeg: ByteArray, complete: (Throwable?) -> Unit) {
        if (closed) { complete(IllegalStateException("监看渲染已关闭")); return }
        if (busy) { complete(IllegalStateException("上一帧仍在渲染")); return }
        busy = true
        worker.execute {
            var failure: Throwable? = null
            try { check(!closed) { "监看渲染已关闭" }; draw(jpeg) }
            catch (e: Throwable) { failure = e }
            finally { busy = false; complete(failure) }
        }
    }
    fun setLut(name:String?, complete:(Throwable?)->Unit) {
        worker.execute { try {
            lut=if(name.isNullOrEmpty()) null else CubeLut.load(context, name)
            if(display!=EGL14.EGL_NO_DISPLAY) uploadLut()
            complete(null)
        } catch(e:Throwable) { complete(e) } }
    }
    private fun shader(kind:Int,asset:String):Int {
        val id=GLES30.glCreateShader(kind); GLES30.glShaderSource(id,context.assets.open(asset).bufferedReader().use { it.readText() }); GLES30.glCompileShader(id)
        val ok=IntArray(1); GLES30.glGetShaderiv(id,GLES30.GL_COMPILE_STATUS,ok,0); check(ok[0]==1) { GLES30.glGetShaderInfoLog(id) }; return id
    }
    private fun initialize(w:Int,h:Int) {
        if (w != width || h != height) entry.surfaceTexture().setDefaultBufferSize(w,h)
        if(display!=EGL14.EGL_NO_DISPLAY) return
        display=EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY); check(EGL14.eglInitialize(display,IntArray(2),0,IntArray(2),0))
        val configs=arrayOfNulls<EGLConfig>(1); val count=IntArray(1)
        check(EGL14.eglChooseConfig(display,intArrayOf(EGL14.EGL_RENDERABLE_TYPE,0x40,EGL14.EGL_SURFACE_TYPE,EGL14.EGL_WINDOW_BIT,EGL14.EGL_RED_SIZE,8,EGL14.EGL_GREEN_SIZE,8,EGL14.EGL_BLUE_SIZE,8,EGL14.EGL_ALPHA_SIZE,8,EGL14.EGL_NONE),0,configs,0,1,count,0) && count[0]>0) { "设备不支持 GLES 3 监看" }
        eglContext=EGL14.eglCreateContext(display,configs[0],EGL14.EGL_NO_CONTEXT,intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION,3,EGL14.EGL_NONE),0)
        surface=Surface(entry.surfaceTexture()); eglSurface=EGL14.eglCreateWindowSurface(display,configs[0],surface,intArrayOf(EGL14.EGL_NONE),0)
        check(EGL14.eglMakeCurrent(display,eglSurface,eglSurface,eglContext))
        val v=shader(GLES30.GL_VERTEX_SHADER,"live_view.vert"); val f=shader(GLES30.GL_FRAGMENT_SHADER,"live_view.frag")
        program=GLES30.glCreateProgram(); GLES30.glAttachShader(program,v); GLES30.glAttachShader(program,f); GLES30.glLinkProgram(program)
        val ok=IntArray(1); GLES30.glGetProgramiv(program,GLES30.GL_LINK_STATUS,ok,0); check(ok[0]==1) { GLES30.glGetProgramInfoLog(program) }; GLES30.glDeleteShader(v); GLES30.glDeleteShader(f)
        val ids=IntArray(1); GLES30.glGenTextures(1,ids,0); texture=ids[0]; GLES30.glBindTexture(GLES30.GL_TEXTURE_2D,texture)
        parameters(GLES30.GL_TEXTURE_2D); uploadLut()
    }
    private fun parameters(target:Int) {
        for(p in intArrayOf(GLES30.GL_TEXTURE_MIN_FILTER,GLES30.GL_TEXTURE_MAG_FILTER)) GLES30.glTexParameteri(target,p,GLES30.GL_LINEAR)
        for(p in intArrayOf(GLES30.GL_TEXTURE_WRAP_S,GLES30.GL_TEXTURE_WRAP_T)) GLES30.glTexParameteri(target,p,GLES30.GL_CLAMP_TO_EDGE)
        if(target==GLES30.GL_TEXTURE_3D) GLES30.glTexParameteri(target,GLES30.GL_TEXTURE_WRAP_R,GLES30.GL_CLAMP_TO_EDGE)
    }
    private fun uploadLut() {
        if(lutTexture!=0) { GLES30.glDeleteTextures(1,intArrayOf(lutTexture),0); lutTexture=0 }
        val cube=lut ?: return; val ids=IntArray(1); GLES30.glGenTextures(1,ids,0); lutTexture=ids[0]
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1); GLES30.glBindTexture(GLES30.GL_TEXTURE_3D,lutTexture); parameters(GLES30.GL_TEXTURE_3D)
        val data=ByteBuffer.allocateDirect(cube.values.size*4).order(ByteOrder.nativeOrder()).asFloatBuffer(); data.put(cube.values).position(0)
        GLES30.glTexImage3D(GLES30.GL_TEXTURE_3D,0,GLES30.GL_RGBA16F,cube.size,cube.size,cube.size,0,GLES30.GL_RGBA,GLES30.GL_FLOAT,data)
        check(GLES30.glGetError()==0) { "监看 LUT 上传失败" }; GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
    }
    private fun draw(bytes:ByteArray) {
        val started = System.nanoTime()
        val bitmap=decoder.decode(bytes)
        if (bitmap == null) {
            droppedFrames++
            if (droppedFrames == 1) {
                // Preserve the actual failing input, not a screenshot, for diagnosis.
                try { java.io.File(context.cacheDir, "monitor-invalid-frame.jpg").writeBytes(bytes) }
                catch (e: Exception) { android.util.Log.w("MirrorBridgeRender", "cannot retain invalid frame", e) }
            }
            if (droppedFrames == 1 || droppedFrames % 60 == 0)
                android.util.Log.w("MirrorBridgeRender", "invalid JPEG dropped count=$droppedFrames bytes=${bytes.size}")
            return
        }
        val decoded = System.nanoTime()
        run {
            initialize(bitmap.width,bitmap.height); GLES30.glActiveTexture(GLES30.GL_TEXTURE0); GLES30.glBindTexture(GLES30.GL_TEXTURE_2D,texture)
            if (bitmap.width == width && bitmap.height == height) GLUtils.texSubImage2D(GLES30.GL_TEXTURE_2D,0,0,0,bitmap)
            else GLUtils.texImage2D(GLES30.GL_TEXTURE_2D,0,bitmap,0)
            width=bitmap.width; height=bitmap.height
            val uploaded = System.nanoTime()
            GLES30.glViewport(0,0,bitmap.width,bitmap.height); GLES30.glUseProgram(program)
            fun int(n:String,v:Int) { GLES30.glUniform1i(location(n),v) }
            fun float(n:String,v:Float) { GLES30.glUniform1f(location(n),v) }
            val o=options
            int("uImage",0); int("uLut",1)
            for((key,uniform) in mapOf("zebra" to "uZebra","peaking" to "uPeaking","mirror" to "uMirror")) int(uniform,if(o[key]==true)1 else 0)
            int("uHasLut",if(lutTexture!=0 && o["lut"]==true)1 else 0); float("uLutIntensity",(o["intensity"] as? Number)?.toFloat() ?: 1f)
            float("uZebraThreshold",(o["zebraThreshold"] as? Number)?.toFloat() ?: .7019608f); float("uPeakingThreshold",(o["peakingThreshold"] as? Number)?.toFloat() ?: .14117648f); float("uOpacity",.86f)
            GLES30.glUniform2f(location("uTexel"),1f/bitmap.width,1f/bitmap.height)
            GLES30.glUniform3fv(location("uLutDomainMin"),1,lut?.domainMin ?: floatArrayOf(0f,0f,0f),0); GLES30.glUniform3fv(location("uLutDomainMax"),1,lut?.domainMax ?: floatArrayOf(1f,1f,1f),0)
            if(lutTexture!=0) { GLES30.glActiveTexture(GLES30.GL_TEXTURE1); GLES30.glBindTexture(GLES30.GL_TEXTURE_3D,lutTexture); GLES30.glActiveTexture(GLES30.GL_TEXTURE0) }
            GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP,0,4); check(GLES30.glGetError()==0) { "监看 GPU 绘制失败" }; check(EGL14.eglSwapBuffers(display,eglSurface))
            val presented = System.nanoTime()
            timingFrames++
            decodeNs += decoded - started
            uploadNs += uploaded - decoded
            presentNs += presented - uploaded
            maxFrameNs = maxOf(maxFrameNs, presented - started)
            if (presented - timingStartNs >= 2_000_000_000L) {
                android.util.Log.i("MirrorBridgeRender", "image=${width}x$height renderedFps=${timingFrames * 1e9 / (presented - timingStartNs)} decodeMs=${decodeNs / timingFrames / 1e6} uploadMs=${uploadNs / timingFrames / 1e6} drawPresentMs=${presentNs / timingFrames / 1e6} maxFrameMs=${maxFrameNs / 1e6} bitmapAllocations=${decoder.allocations}")
                timingStartNs = presented; timingFrames = 0; decodeNs = 0; uploadNs = 0; presentNs = 0; maxFrameNs = 0
            }
            frames++
            val info = mutableMapOf<String, Any?>("type" to "gpuFrame", "textureId" to id,
                "width" to width, "height" to height, "frames" to frames)
            val now=android.os.SystemClock.elapsedRealtime()
            if ((o["histogram"] == true || o["waveform"] == true) && now-lastScopeMs >= 200) {
                lastScopeMs=now
                val histogramEnabled = o["histogram"] == true
                val waveformEnabled = o["waveform"] == true
                val rgb = scopeHistogram; val wave = scopeWave
                if (histogramEnabled) { rgb.red.fill(0); rgb.green.fill(0); rgb.blue.fill(0) }
                if (waveformEnabled) wave.fill(0)
                if (scopeRow.size != width) scopeRow = IntArray(width)
                val row = scopeRow
                val yStep=maxOf(1,height/90)
                for(yPos in 0 until height step yStep) {
                    bitmap.getPixels(row,0,width,0,yPos,width,1)
                    for(xPos in 0 until 160) {
                        val pixel=row[minOf(width-1,xPos*width/160)]
                        if (histogramEnabled) rgb.add(pixel)
                        if (waveformEnabled) {
                            val luma=((.299f*((pixel shr 16) and 255)+.587f*((pixel shr 8) and 255)+.114f*(pixel and 255)).toInt()/4).coerceIn(0,63)
                            wave[(63-luma)*160+xPos]++
                        }
                    }
                }
                if(o["histogram"] == true) info["histogramRgb"]=rgb.channels()
                if(o["waveform"] == true) info["waveform"]=wave.toList()
            }
            event(info)
        }
    }
    fun close() {
        if(closed) return; closed=true
        worker.execute {
            decoder.close()
            if(display!=EGL14.EGL_NO_DISPLAY) { GLES30.glDeleteTextures(1,intArrayOf(texture),0); if(lutTexture!=0) GLES30.glDeleteTextures(1,intArrayOf(lutTexture),0); if(program!=0) GLES30.glDeleteProgram(program); EGL14.eglMakeCurrent(display,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_CONTEXT); EGL14.eglDestroySurface(display,eglSurface); EGL14.eglDestroyContext(display,eglContext); EGL14.eglTerminate(display) }
            surface?.release(); Handler(Looper.getMainLooper()).post { entry.release() }
        }; worker.shutdown()
    }
}
