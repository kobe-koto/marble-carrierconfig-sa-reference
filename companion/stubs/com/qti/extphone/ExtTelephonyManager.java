package com.qti.extphone;
import android.content.Context;
public class ExtTelephonyManager {
  public static ExtTelephonyManager getInstance(Context context) { return null; }
  public boolean connectService(ServiceCallback callback) { return false; }
  public void disconnectService(ServiceCallback callback) {}
  public Client registerCallback(String packageName, IExtPhoneCallback callback) { return null; }
  public void unRegisterCallback(IExtPhoneCallback callback) {}
  public Token queryNrConfig(int slot, Client client) { return null; }
  public Token setNrConfig(int slot, NrConfig config, Client client) { return null; }
}
