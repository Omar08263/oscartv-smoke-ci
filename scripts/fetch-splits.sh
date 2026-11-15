#!/usr/bin/env bash
# Fetch the REAL split APKs for Game of Sultans 7.804 (com.dc.hwsj).
# Source: APKPure XAPK (base + all splits, ~1.6 GB) via d.apkpure.com.
# The base APK alone cannot run: the Dianchu KSecure native lib
# (libclthkasc.so, loaded by KSecureValidation.<clinit> at app start)
# and the Solar2D runtime live in the ABI split (config.arm64_v8a),
# which is NOT in the base file. CoronaCards libs alone are NOT enough:
# Redroid run 43699371020 proved install OK but a fatal
# UnsatisfiedLinkError: libclthkasc.so not found at attachBaseContext.
# Expected split md5s (from Aptoide web data, verified against the base):
#   config.arm64_v8a  8788749 B  md5 9070f173830a2c9c35a469267c3097db
#   config.mdpi        274185 B  md5 e0843b857101ff956a9c26329cbadff3
#   config.en           94958 B  md5 c89f38381a9f9b02618b8629df3787fc
# Outputs (artifacts/): config.arm64_v8a.apk, config.mdpi.apk, config.en.apk
# + SPLITS.md with sizes/md5s and the .so inventory of the arm64 split.
set -u
mkdir -p artifacts splits
exec > >(tee artifacts/run.log) 2>&1

XAPK_URL="https://d.apkpure.com/b/XAPK/com.dc.hwsj?version=latest"
XAPK="game-of-sultans-7.804.xapk"

echo "== download XAPK (expect ~1646984535 B) =="
curl -sS -L --max-time 1500 -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36" \
  -o "$XAPK" -w "HTTP %{http_code} size %{size_download} time %{time_total}s\n" "$XAPK_URL"
ls -l "$XAPK"
file "$XAPK"
python3 - "$XAPK" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
for i in z.infolist():
    print(f"{i.file_size:>12}  {i.filename}")
PY

echo "== extract splits =="
unzip -o -j "$XAPK" "config.arm64_v8a.apk" "config.mdpi.apk" "config.en.apk" -d splits/ 2>&1 | tail -5
ls -l splits/
md5sum splits/*.apk | tee artifacts/SPLITS.md
python3 - <<'PY' | tee -a artifacts/SPLITS.md
import hashlib
exp = {
  "config.arm64_v8a.apk": ("9070f173830a2c9c35a469267c3097db", 8788749),
  "config.mdpi.apk": ("e0843b857101ff956a9c26329cbadff3", 274185),
  "config.en.apk": ("c89f38381a9f9b02618b8629df3787fc", 94958),
}
ok = True
for name, (md5, size) in exp.items():
    p = f"splits/{name}"
    d = open(p, "rb").read()
    got_md5 = hashlib.md5(d).hexdigest()
    got_size = len(d)
    status = "OK" if (got_md5 == md5 and got_size == size) else "MISMATCH"
    if status != "OK":
        ok = False
    print(f"{name}: md5 {got_md5} (expect {md5}) size {got_size} (expect {size}) -> {status}")
print("ALL SPLITS VERIFIED" if ok else "SPLIT VERIFICATION FAILED")
PY

echo "== .so inventory of the arm64 split =="
python3 - <<'PY' | tee -a artifacts/SPLITS.md
import zipfile
z = zipfile.ZipFile("splits/config.arm64_v8a.apk")
sos = [i for i in z.infolist() if i.filename.endswith(".so")]
print(f"native libs in config.arm64_v8a.apk: {len(sos)}")
for i in sos:
    print(f"  {i.file_size:>10}  {i.filename}  method={i.compress_type}")
others = [i.filename for i in z.infolist() if not i.filename.endswith(".so")]
print("non-.so entries:", others)
PY

echo "== aapt2 badging of the arm64 split =="
(aapt2 dump badging splits/config.arm64_v8a.apk 2>/dev/null || ~/android-sdk/build-tools/34.0.0/aapt2 dump badging splits/config.arm64_v8a.apk 2>/dev/null || echo "aapt2 not available on runner") | head -5 || true

cp splits/*.apk artifacts/ 2>/dev/null || true
echo DONE
