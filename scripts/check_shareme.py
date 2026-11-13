#!/usr/bin/env python3
"""Best-effort ShareMe mod check on the emulator.

- Scans all UI dumps for ad-activity markers (AdView / AdMob / banner /
  splash-ad / native-ad / gms.ads). The mod kills ads at the source
  (AdSetting getters, MiSplashAdSetting, ad/c.d+f, P4/e.a), so a clean
  home dump + no ad view in the hierarchy is the expected evidence.
- Tries to tap the Send button, captures the send screen, goes back,
  tries the Receive button, captures that screen. All best-effort:
  only writes artifacts/shareme-check.txt, never fails the job.
"""
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

OUT = "artifacts/shareme-check.txt"
AD_MARKERS = [
    "AdView", "adview", "AdMob", "admob", "gms.ads", "google.ads",
    "splash_ad", "banner_ad", "native_ad", "bannerAd", "interstitial",
    "advertisement", "Advertisement", "AdActivity", "ad_container",
    "adview_container", "MiSplashAd", "AdSetting",
]
SEND_WORDS = ["Send", "send", "إرسال", "ارسال"]
RECV_WORDS = ["Receive", "receive", "استلام", "إستلام"]

log = []


def run(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return r.stdout + r.stderr


def read(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            return f.read()
    except FileNotFoundError:
        return None


def find_node(path, words):
    try:
        tree = ET.parse(path)
    except Exception as e:
        log.append(f"cannot parse {path}: {e}")
        return None
    for node in tree.iter("node"):
        text = (node.get("text") or "") + " " + (node.get("content-desc") or "") + " " + (node.get("resource-id") or "")
        if any(w in text for w in words):
            if node.get("clickable") == "true":
                return node
    return None


def center(node):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds") or "")
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


def tap_capture(label, words, shot, dump):
    home = "artifacts/ui-home2.xml"
    node = find_node(home, words)
    if node is None:
        home = "artifacts/ui-home.xml"
        node = find_node(home, words)
    if node is None:
        log.append(f"{label} button: NOT FOUND in home dumps (best effort only)")
        return False
    c = center(node)
    if not c:
        log.append(f"{label} button: found but no bounds, cannot tap")
        return False
    log.append(f"{label} button: found in {home}, tapping {c}")
    run(f"adb shell input tap {c[0]} {c[1]}")
    time.sleep(6)
    run(f"adb shell screencap -p /sdcard/{shot}.png")
    run(f"adb pull /sdcard/{shot}.png artifacts/{shot}.png")
    run(f"adb shell uiautomator dump /sdcard/ui-{dump}.xml")
    run(f"adb pull /sdcard/ui-{dump}.xml artifacts/ui-{dump}.xml")
    run("adb shell input keyevent 4")  # back to home
    time.sleep(4)
    return True


def main():
    # 1. ad-marker scan over every dump we have
    for path in ["artifacts/ui-home.xml", "artifacts/ui-home2.xml",
                 "artifacts/ui-send.xml", "artifacts/ui-receive.xml"]:
        data = read(path)
        if data is None:
            log.append(f"{path}: not present")
            continue
        found = [w for w in AD_MARKERS if w in data]
        log.append(f"{path}: ad markers found: {found if found else 'NONE'}")
    # 2. navigation: Send then Receive
    tap_capture("Send", SEND_WORDS, "send", "send")
    tap_capture("Receive", RECV_WORDS, "receive", "receive")
    # 3. re-scan the navigation dumps if they appeared after step 1
    for path in ["artifacts/ui-send.xml", "artifacts/ui-receive.xml"]:
        data = read(path)
        if data is not None:
            found = [w for w in AD_MARKERS if w in data]
            log.append(f"{path} (after nav): ad markers found: {found if found else 'NONE'}")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(log) + "\n")
    print("\n".join(log))
    return 0


if __name__ == "__main__":
    sys.exit(main())
