package com.familyscreen.sender;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.util.Base64;
import android.util.DisplayMetrics;
import android.view.Display;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.concurrent.TimeUnit;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;

/**
 * Captures the screen and relays ~1 JPEG per second over a Supabase Realtime broadcast channel,
 * only while a viewer has pinged in the last 15 s. The notification always says when someone is watching.
 */
public class CaptureService extends Service {
    static final String ACTION_STOP = "stop";
    static final String EXTRA_RESULT_CODE = "resultCode";
    static final String EXTRA_DATA = "data";

    // Same values as the iOS app's Config.swift. Publishable key: safe to ship in an app.
    private static final String SUPABASE_HOST = "pkcocejpyjphjtqgkoli.supabase.co";
    private static final String SUPABASE_KEY = "sb_publishable_T1JWV4I67eMM53CK3XCTcQ_Tw7QP4iS";

    private static final int WIDTH = 540;
    private static final long FRAME_MS = 1000;
    private static final long VIEWER_TIMEOUT_MS = 15_000;
    private static final int MAX_PAYLOAD_CHARS = 200_000; // Realtime rejects very large broadcasts
    private static final String CHANNEL = "sharing";

    private final OkHttpClient http = new OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).build();
    private HandlerThread thread;
    private Handler handler;
    private MediaProjection projection;
    private VirtualDisplay display;
    private ImageReader reader;
    private WebSocket socket;
    private String topic;
    private int ref = 1;
    private String joinRef = "1";
    private final Runnable heartbeatLoop = this::heartbeat;
    private boolean stopped;
    private boolean watchedShown;
    private volatile long lastViewerPing;

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || ACTION_STOP.equals(intent.getAction()) || projection != null) {
            if (intent != null && ACTION_STOP.equals(intent.getAction())) stopSelf();
            return START_NOT_STICKY;
        }
        Intent data = intent.getParcelableExtra(EXTRA_DATA);
        if (data == null) { stopSelf(); return START_NOT_STICKY; }

        getSystemService(NotificationManager.class).createNotificationChannel(
                new NotificationChannel(CHANNEL, "Screen sharing", NotificationManager.IMPORTANCE_LOW));
        // Android 14: must be foreground with the mediaProjection type before getMediaProjection().
        startForeground(1, notification(false), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);

        MediaProjectionManager mpm = getSystemService(MediaProjectionManager.class);
        projection = mpm.getMediaProjection(intent.getIntExtra(EXTRA_RESULT_CODE, 0), data);
        if (projection == null) { stopSelf(); return START_NOT_STICKY; }

        thread = new HandlerThread("capture");
        thread.start();
        handler = new Handler(thread.getLooper());
        projection.registerCallback(new MediaProjection.Callback() {
            @Override public void onStop() { stopSelf(); } // user ended it from the status bar
        }, handler);

        DisplayMetrics real = new DisplayMetrics();
        getSystemService(DisplayManager.class).getDisplay(Display.DEFAULT_DISPLAY).getRealMetrics(real);
        int height = (real.heightPixels * WIDTH / real.widthPixels) & ~1;
        int dpi = Math.max(120, real.densityDpi * WIDTH / real.widthPixels);
        // shortcut: size is fixed at start, so landscape apps show letterboxed; recreate the display on rotation if that matters.
        reader = ImageReader.newInstance(WIDTH, height, PixelFormat.RGBA_8888, 2);
        display = projection.createVirtualDisplay("family-screen", WIDTH, height, dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, reader.getSurface(), null, handler);

        topic = "realtime:family-" + MainActivity.familyCode(this);
        connect();
        handler.post(this::tick);
        return START_NOT_STICKY;
    }

    private Notification notification(boolean watched) {
        PendingIntent stop = PendingIntent.getService(this, 0,
                new Intent(this, CaptureService.class).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.presence_video_online)
                .setContentTitle(watched ? "A family member is watching your screen" : "Family Screen is on")
                .setContentText(watched ? "They can see what's on your screen right now." : "Family can view your screen when they open the app.")
                .setOngoing(true)
                .addAction(new Notification.Action.Builder(null, "Stop", stop).build())
                .build();
    }

    private void tick() {
        if (stopped) return;
        boolean watched = System.currentTimeMillis() - lastViewerPing < VIEWER_TIMEOUT_MS;
        if (watched != watchedShown) {
            watchedShown = watched;
            getSystemService(NotificationManager.class).notify(1, notification(watched));
        }
        Image image = reader.acquireLatestImage(); // always drain so the next frame is fresh
        if (image != null) {
            try {
                if (watched && socket != null) sendFrame(image);
            } catch (Exception ignored) {
                // a dropped frame is harmless; the next tick sends another
            } finally {
                image.close();
            }
        }
        handler.postDelayed(this::tick, FRAME_MS);
    }

    private void sendFrame(Image image) throws Exception {
        Image.Plane plane = image.getPlanes()[0];
        ByteBuffer buffer = plane.getBuffer();
        int w = image.getWidth(), h = image.getHeight();
        int rowPixels = plane.getRowStride() / plane.getPixelStride(); // rows can be padded
        Bitmap padded = Bitmap.createBitmap(rowPixels, h, Bitmap.Config.ARGB_8888);
        padded.copyPixelsFromBuffer(buffer);
        Bitmap frame = rowPixels == w ? padded : Bitmap.createBitmap(padded, 0, 0, w, h);

        String jpg = jpeg(frame, 50);
        if (jpg.length() > MAX_PAYLOAD_CHARS) jpg = jpeg(frame, 25);
        if (jpg.length() > MAX_PAYLOAD_CHARS) return;

        JSONObject inner = new JSONObject().put("jpg", jpg).put("w", w).put("h", h).put("t", System.currentTimeMillis());
        push("broadcast", new JSONObject().put("type", "broadcast").put("event", "frame").put("payload", inner), topic);
    }

    private static String jpeg(Bitmap bmp, int quality) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        bmp.compress(Bitmap.CompressFormat.JPEG, quality, out);
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP);
    }

    // --- Supabase Realtime (Phoenix protocol) ---

    private void connect() {
        if (stopped) return;
        Request req = new Request.Builder()
                .url("wss://" + SUPABASE_HOST + "/realtime/v1/websocket?apikey=" + SUPABASE_KEY + "&vsn=1.0.0")
                .build();
        socket = http.newWebSocket(req, new WebSocketListener() {
            @Override public void onOpen(WebSocket ws, Response response) {
                try {
                    JSONObject config = new JSONObject()
                            .put("broadcast", new JSONObject().put("self", false))
                            .put("presence", new JSONObject().put("key", ""));
                    push("phx_join", new JSONObject().put("config", config), topic);
                    handler.removeCallbacks(heartbeatLoop);
                    handler.post(heartbeatLoop);
                } catch (Exception e) { ws.cancel(); }
            }

            @Override public void onMessage(WebSocket ws, String text) {
                try {
                    JSONObject msg = new JSONObject(text);
                    if (!"broadcast".equals(msg.optString("event"))) return;
                    if ("watch".equals(msg.optJSONObject("payload").optString("event"))) {
                        lastViewerPing = System.currentTimeMillis();
                    }
                } catch (Exception ignored) { }
            }

            @Override public void onFailure(WebSocket ws, Throwable t, Response r) { reconnect(ws); }
            @Override public void onClosed(WebSocket ws, int code, String reason) { reconnect(ws); }
        });
    }

    private void reconnect(WebSocket dead) {
        if (dead != socket || stopped) return;
        socket = null;
        handler.postDelayed(this::connect, 5000);
    }

    private void heartbeat() {
        if (stopped || socket == null) return;
        try { push("heartbeat", new JSONObject(), "phoenix"); } catch (Exception ignored) { }
        handler.postDelayed(heartbeatLoop, 25_000);
    }

    private synchronized void push(String event, JSONObject payload, String toTopic) throws Exception {
        WebSocket ws = socket;
        if (ws == null) return;
        ref++;
        if ("phx_join".equals(event)) joinRef = String.valueOf(ref);
        JSONObject frame = new JSONObject().put("topic", toTopic).put("event", event)
                .put("payload", payload).put("ref", String.valueOf(ref));
        if (!"phoenix".equals(toTopic)) frame.put("join_ref", joinRef);
        ws.send(frame.toString());
    }

    @Override
    public void onDestroy() {
        stopped = true;
        if (handler != null) handler.removeCallbacksAndMessages(null);
        if (socket != null) socket.close(1000, null);
        if (display != null) display.release();
        if (reader != null) reader.close();
        if (projection != null) projection.stop();
        if (thread != null) thread.quitSafely();
        super.onDestroy();
    }
}
