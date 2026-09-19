package io.github.evox.carrierconfig.sa.enforcer;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;
import android.os.PersistableBundle;
import android.telephony.CarrierConfigManager;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.util.Log;

import com.qti.extphone.Client;
import com.qti.extphone.ExtPhoneCallbackBase;
import com.qti.extphone.ExtTelephonyManager;
import com.qti.extphone.NrConfig;
import com.qti.extphone.ServiceCallback;
import com.qti.extphone.Status;
import com.qti.extphone.Token;

import java.io.File;
import java.io.FileWriter;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Applies Qualcomm combined SA+NSA mode when the final CarrierConfig allows it. */
public final class SaModeReceiver extends BroadcastReceiver {
    private static final String TAG = "CarrierConfigSa";
    private static Controller current;

    @Override
    public void onReceive(Context context, Intent intent) {
        PendingResult pending = goAsync();
        synchronized (SaModeReceiver.class) {
            if (current != null) {
                Log.i(TAG, "Coalescing broadcast " + intent.getAction());
                current.addPending(pending);
                return;
            }
            current = new Controller(context.getApplicationContext(), pending);
        }
        Log.i(TAG, "Received " + intent.getAction());
        current.start();
    }

    private static final class Controller {
        private static final String KEY_NR_AVAIL = "carrier_nr_availabilities_int_array";
        private static final String KEY_SA_AVAILABLE = "carrier_sa_mode_available_bool";
        private static final String KEY_DISABLE_SA = "carrier_disable_sa_mode_bool";
        private static final String KEY_DISABLE_VICE_SA = "carrier_disable_vice_sa_mode_bool";
        private static final int NR_COMBINED = 0;
        private static final int STATUS_SUCCESS = 1;
        private static final long TIMEOUT_MS = 30_000L;

        private final Context context;
        private final Handler handler = new Handler(Looper.getMainLooper());
        private final ArrayList<PendingResult> pendingResults = new ArrayList<>();
        private final Set<Integer> eligibleSlots = new HashSet<>();
        private final Set<Integer> completedSlots = new HashSet<>();
        private final Map<Integer, String> phases = new HashMap<>();
        private final Callback callback = new Callback();
        private ExtTelephonyManager manager;
        private ServiceCallback serviceCallback;
        private Client client;
        private boolean finished;

        Controller(Context context, PendingResult pending) {
            this.context = context.createDeviceProtectedStorageContext();
            pendingResults.add(pending);
            audit("Controller created");
        }

        synchronized void addPending(PendingResult pending) {
            if (finished) pending.finish(); else pendingResults.add(pending);
        }

        void start() {
            handler.post(() -> {
                try {
                    discoverEligibleSlots();
                    if (eligibleSlots.isEmpty()) {
                        finish("No eligible active slots");
                        return;
                    }
                    manager = ExtTelephonyManager.getInstance(context);
                    serviceCallback = new ServiceCallback() {
                        @Override public void onConnected() { serviceConnected(); }
                        @Override public void onDisconnected() {
                            if (!finished) finish("ExtTelephony disconnected");
                        }
                    };
                    boolean binding = manager.connectService(serviceCallback);
                    audit("connectService=" + binding + " eligibleSlots=" + eligibleSlots);
                    if (!binding) finish("ExtTelephony bind failed");
                    handler.postDelayed(() -> finish("Timed out"), TIMEOUT_MS);
                } catch (Throwable t) {
                    audit("Start failed: " + t);
                    Log.e(TAG, "Start failed", t);
                    finish("Start exception");
                }
            });
        }

        private void discoverEligibleSlots() {
            SubscriptionManager sm = context.getSystemService(SubscriptionManager.class);
            CarrierConfigManager ccm = context.getSystemService(CarrierConfigManager.class);
            List<SubscriptionInfo> infos = sm == null ? null : sm.getActiveSubscriptionInfoList();
            if (infos == null) infos = new ArrayList<>();
            for (SubscriptionInfo info : infos) {
                int subId = info.getSubscriptionId();
                int slot = info.getSimSlotIndex();
                PersistableBundle config = ccm == null ? null : ccm.getConfigForSubId(subId);
                int[] nr = config == null ? null : config.getIntArray(KEY_NR_AVAIL);
                boolean eligible = config != null
                        && config.getBoolean(KEY_SA_AVAILABLE, false)
                        && !config.getBoolean(KEY_DISABLE_SA, true)
                        && !config.getBoolean(KEY_DISABLE_VICE_SA, true)
                        && contains(nr, 1) && contains(nr, 2);
                audit("subId=" + subId + " slot=" + slot
                        + " plmn=" + info.getMccString() + info.getMncString()
                        + " nr=" + arrayString(nr)
                        + " saAvailable=" + bool(config, KEY_SA_AVAILABLE, false)
                        + " disableSa=" + bool(config, KEY_DISABLE_SA, true)
                        + " disableViceSa=" + bool(config, KEY_DISABLE_VICE_SA, true)
                        + " eligible=" + eligible);
                if (slot >= 0 && eligible) eligibleSlots.add(slot);
            }
        }

        private void serviceConnected() {
            audit("ExtTelephony connected");
            client = manager.registerCallback(context.getPackageName(), callback);
            audit("registered client=" + client);
            if (client == null) {
                finish("Callback registration failed");
                return;
            }
            for (int slot : eligibleSlots) phases.put(slot, "initial-query");
            for (int slot : new ArrayList<>(eligibleSlots)) {
                Token token = manager.queryNrConfig(slot, client);
                audit("Initial query slot=" + slot + " token=" + token);
                if (token == null) finish("Initial query rejected for slot " + slot);
            }
        }

        private final class Callback extends ExtPhoneCallbackBase {
            @Override
            public void onNrConfigStatus(int slot, Token token, Status status, NrConfig config) {
                handler.post(() -> handleNrConfig(slot, token, status, config));
            }

            @Override
            public void onSetNrConfig(int slot, Token token, Status status) {
                handler.post(() -> handleSetResult(slot, token, status));
            }
        }

        private void handleNrConfig(int slot, Token token, Status status, NrConfig config) {
            if (finished || !eligibleSlots.contains(slot)) return;
            int statusValue = status == null ? -1 : status.get();
            int value = config == null ? -1 : config.get();
            String phase = phases.get(slot);
            audit("onNrConfigStatus slot=" + slot + " phase=" + phase
                    + " status=" + statusValue + " value=" + value + " token=" + token);
            if (statusValue != STATUS_SUCCESS || config == null) {
                finish("Query failed for slot " + slot);
            } else if (value == NR_COMBINED) {
                completeSlot(slot);
            } else if ("verify".equals(phase)) {
                finish("Verification returned " + value + " for slot " + slot);
            } else {
                phases.put(slot, "set");
                Token setToken = manager.setNrConfig(slot, new NrConfig(NR_COMBINED), client);
                audit("setNrConfig slot=" + slot + " target=0 token=" + setToken);
                if (setToken == null) finish("Set rejected for slot " + slot);
            }
        }

        private void handleSetResult(int slot, Token token, Status status) {
            if (finished || !eligibleSlots.contains(slot)) return;
            int statusValue = status == null ? -1 : status.get();
            audit("onSetNrConfig slot=" + slot + " status=" + statusValue
                    + " token=" + token);
            if (statusValue != STATUS_SUCCESS) {
                finish("Set failed for slot " + slot);
                return;
            }
            phases.put(slot, "verify");
            handler.postDelayed(() -> {
                if (finished) return;
                Token verify = manager.queryNrConfig(slot, client);
                audit("Verify query slot=" + slot + " token=" + verify);
                if (verify == null) finish("Verify rejected for slot " + slot);
            }, 700L);
        }

        private void completeSlot(int slot) {
            completedSlots.add(slot);
            phases.put(slot, "done");
            audit("Confirmed combined slot=" + slot + " completed=" + completedSlots);
            if (completedSlots.containsAll(eligibleSlots)) finish("All eligible slots confirmed combined");
        }

        private void finish(String reason) {
            if (Looper.myLooper() != Looper.getMainLooper()) {
                handler.post(() -> finish(reason));
                return;
            }
            if (finished) return;
            finished = true;
            audit("Finish: " + reason);
            try {
                if (manager != null && client != null) manager.unRegisterCallback(callback);
            } catch (Throwable t) {
                Log.w(TAG, "Callback cleanup failed", t);
            }
            try {
                if (manager != null && serviceCallback != null) manager.disconnectService(serviceCallback);
            } catch (Throwable t) {
                Log.w(TAG, "Service cleanup failed", t);
            }
            for (PendingResult pending : pendingResults) pending.finish();
            pendingResults.clear();
            synchronized (SaModeReceiver.class) {
                if (current == this) current = null;
            }
        }

        private void audit(String message) {
            Log.i(TAG, message);
            try {
                File dir = context.getFilesDir();
                if (dir == null) return;
                File file = new File(dir, "nr-mode-enforcer.log");
                if (file.length() > 65536L) {
                    File old = new File(dir, "nr-mode-enforcer.log.old");
                    if (old.exists()) old.delete();
                    file.renameTo(old);
                }
                try (FileWriter writer = new FileWriter(file, true)) {
                    writer.write(new Date().toString());
                    writer.write(" ");
                    writer.write(message.replace('\n', ' '));
                    writer.write("\n");
                }
            } catch (Throwable t) {
                Log.w(TAG, "Audit write failed", t);
            }
        }

        private static boolean bool(PersistableBundle b, String key, boolean fallback) {
            return b == null ? fallback : b.getBoolean(key, fallback);
        }

        private static boolean contains(int[] values, int wanted) {
            if (values == null) return false;
            for (int value : values) if (value == wanted) return true;
            return false;
        }

        private static String arrayString(int[] values) {
            if (values == null) return "null";
            StringBuilder out = new StringBuilder("[");
            for (int i = 0; i < values.length; i++) {
                if (i > 0) out.append(',');
                out.append(values[i]);
            }
            return out.append(']').toString();
        }
    }
}
