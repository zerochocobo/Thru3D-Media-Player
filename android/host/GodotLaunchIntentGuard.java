package com.godot.game;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;

/** Applied before GodotActivity processes launch controls; never logs Intent contents. */
final class GodotLaunchIntentGuard {
    private GodotLaunchIntentGuard() {}

    static Intent sanitize(Activity host, Intent intent) {
        if (intent == null) return null;
        boolean external = true;
        try {
            ComponentName target = intent.getComponent();
            if (target != null) {
                ActivityInfo info = host.getPackageManager().getActivityInfo(target, 0);
                external = info.exported || info.applicationInfo.uid != host.getApplicationInfo().uid;
            }
        } catch (PackageManager.NameNotFoundException | RuntimeException ignored) {
            // Unknown routing is untrusted. Internal explicit, non-exported restarts remain valid.
        }
        if (external) {
            try {
                intent.removeExtra("new_launch_requested");
                intent.removeExtra("command_line_params");
            } catch (RuntimeException ignored) {
                // A malformed Bundle cannot reach the engine's launch-control parser.
                intent.replaceExtras((Bundle) null);
            }
        }
        return intent;
    }
}
