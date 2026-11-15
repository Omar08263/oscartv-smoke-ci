#!/usr/bin/env bash
# Fetch Game of Sultans 7.804 base + splits STRAIGHT FROM GOOGLE PLAY via
# goopdl (anonymous auth through Aurora Store's token dispenser — no Google
# account, no browser). The dispenser is Cloudflare-blocked from our VM, so
# this runs on the GitHub runner instead.
# Why: the mod installs (Redroid 43699371020) but crashes at startup —
# libclthkasc.so (Dianchu KSecure, loaded by KSecureValidation.<clinit>)
# lives in the REAL ABI split (config.arm64_v8a), which no mirror will serve
# to a datacenter IP (APKPure 403, Uptodown needs JS, Aptoide hides split URLs).
# Play's splits are the genuine article: verify config.arm64_v8a against the
# Aptoide-listed md5 9070f173830a2c9c35a469267c3097db (size 8788749).
# Expected Play version: 7.804 / 66780401 (updated 2026-11-07). If Play has
# moved to a newer versionCode, the md5 will NOT match — report it, do not
# force it: a mismatched lib may not belong to our base.
set -u
mkdir -p artifacts play
exec > >(tee artifacts/run.log) 2>&1

python3 -m venv .venv 2>&1 | tail -1
.venv/bin/pip install -q goopdl 2>&1 | tail -2
.venv/bin/goopdl --version 2>&1 | head -2

echo "== app info (tests anonymous auth) =="
.venv/bin/goopdl info com.dc.hwsj 2>&1 | tee artifacts/info.txt | head -30

echo "== list splits =="
.venv/bin/goopdl list-splits com.dc.hwsj 2>&1 | tee artifacts/splits-list.txt | head -40

echo "== download base + splits =="
.venv/bin/goopdl download com.dc.hwsj -o play/ 2>&1 | tee artifacts/download.log | tail -20
ls -l play/ 2>&1 | tee -a artifacts/run.log

echo "== verify: sizes + md5s + badging =="
md5sum play/*.apk 2>/dev/null | tee artifacts/PLAY.md5 || true
python3 - <<'PY' | tee -a artifacts/PLAY.md5
import hashlib, glob, os
for p in sorted(glob.glob("play/*.apk")):
    d = open(p, "rb").read()
    print(f"{os.path.basename(p)}: size {len(d)} md5 {hashlib.md5(d).hexdigest()}")
exp_md5 = "9070f173830a2c9c35a469267c3097db"
for p in glob.glob("play/*.apk"):
    if hashlib.md5(open(p, "rb").read()).hexdigest() == exp_md5:
        print(f"MATCH: {p} IS the genuine config.arm64_v8a (md5 {exp_md5})")
PY
for f in play/*.apk; do echo "--- $f"; (aapt2 dump badging "$f" 2>/dev/null || echo "aapt2 not on runner") | head -3; done

cp play/*.apk artifacts/ 2>/dev/null || true
cp artifacts/info.txt artifacts/splits-list.txt artifacts/download.log artifacts/PLAY.md5 artifacts/ 2>/dev/null || true
echo DONE
