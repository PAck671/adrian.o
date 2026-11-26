package com.familyscreen.sender;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.security.SecureRandom;

/** Shows the family code and starts/stops sharing. Android asks for screen-capture consent on every start. */
public class MainActivity extends Activity {
    private static final int REQ_CAPTURE = 1;

    /** Room code family members type into the iPhone app. No 0/O/1/I/L so it reads cleanly aloud. */
    static String familyCode(Context ctx) {
        SharedPreferences prefs = ctx.getSharedPreferences("family", MODE_PRIVATE);
        String code = prefs.getString("code", null);
        if (code == null) {
            String alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
            SecureRandom rnd = new SecureRandom();
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 10; i++) sb.append(alphabet.charAt(rnd.nextInt(alphabet.length())));
            code = sb.toString();
            prefs.edit().putString("code", code).apply();
        }
        return code;
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 0);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        root.setPadding(48, 48, 48, 48);

        TextView label = new TextView(this);
        label.setText("Family code");
        label.setGravity(Gravity.CENTER);
        TextView code = new TextView(this);
        code.setText(familyCode(this));
        code.setTextSize(36);
        code.setTextIsSelectable(true);
        code.setGravity(Gravity.CENTER);

        Button start = new Button(this);
        start.setText("Start sharing screen");
        start.setOnClickListener(v -> {
            MediaProjectionManager mpm = getSystemService(MediaProjectionManager.class);
            startActivityForResult(mpm.createScreenCaptureIntent(), REQ_CAPTURE);
        });
        Button stop = new Button(this);
        stop.setText("Stop sharing");
        stop.setOnClickListener(v -> startService(new Intent(this, CaptureService.class).setAction(CaptureService.ACTION_STOP)));

        root.addView(label);
        root.addView(code);
        root.addView(start);
        root.addView(stop);
        setContentView(root);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQ_CAPTURE || resultCode != RESULT_OK || data == null) return;
        Intent svc = new Intent(this, CaptureService.class)
                .putExtra(CaptureService.EXTRA_RESULT_CODE, resultCode)
                .putExtra(CaptureService.EXTRA_DATA, data);
        startForegroundService(svc);
        moveTaskToBack(true);
    }
}
