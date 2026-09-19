package com.qti.extphone;
public class ExtPhoneCallbackBase implements IExtPhoneCallback {
  public void onNrConfigStatus(int slot, Token token, Status status, NrConfig config) {}
  public void onSetNrConfig(int slot, Token token, Status status) {}
}
