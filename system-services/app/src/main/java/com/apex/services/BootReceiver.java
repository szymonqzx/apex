package com.apex.services;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.ServiceManager;
import android.util.Log;

import com.apex.agent.LlmManagerService;
import com.apex.wm.ApexWindowManager;
import com.apex.desktop.DesktopModeService;
import com.apex.lindroid.LindroidManager;

/**
 * Boot receiver that publishes all APEX system services to ServiceManager.
 * Runs at BOOT_COMPLETED with system UID (via android:sharedUserId).
 */
public class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "ApexServices";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            return;
        }
        Log.i(TAG, "Boot completed — publishing APEX system services");

        // Publish agent service
        try {
            LlmManagerService agentService = new LlmManagerService(context);
            agentService.publish();
            Log.i(TAG, "Agent service published");
        } catch (Exception e) {
            Log.e(TAG, "Failed to publish agent service", e);
        }

        // Publish window manager
        try {
            ApexWindowManager wm = new ApexWindowManager(context);
            wm.publish();
            Log.i(TAG, "Window manager published");
        } catch (Exception e) {
            Log.e(TAG, "Failed to publish window manager", e);
        }

        // Publish desktop mode service
        try {
            DesktopModeService desktop = new DesktopModeService(context);
            desktop.publish();
            Log.i(TAG, "Desktop mode service published");
        } catch (Exception e) {
            Log.e(TAG, "Failed to publish desktop service", e);
        }

        // Publish Lindroid manager
        try {
            LindroidManager lindroid = new LindroidManager(context);
            lindroid.publish();
            Log.i(TAG, "Lindroid manager published");
        } catch (Exception e) {
            Log.e(TAG, "Failed to publish Lindroid manager", e);
        }

        Log.i(TAG, "All APEX system services published");
    }
}
