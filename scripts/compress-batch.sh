#!/usr/bin/env bash
set -euo pipefail

if [ -z "$ALBUM" ] || [ -z "$STAGING_PREFIX" ] || [ -z "$TARGET_PREFIX" ]; then
  echo "##[error]ALBUM / STAGING_PREFIX / TARGET_PREFIX kosong, batalkan."
  exit 1
fi

echo "Album: $ALBUM"
echo "Staging prefix: $STAGING_PREFIX"
echo "Target prefix:  $TARGET_PREFIX"

AWS="aws --endpoint-url $R2_ENDPOINT"

# Bersihkan file sementara otomatis, apa pun yang terjadi (sukses/gagal/dibatalkan)
cleanup() { rm -f /tmp/src_* /tmp/out_* /tmp/poster_* /tmp/webhook_body_* staging_keys.json; }
trap cleanup EXIT

# Fungsi retry generik: coba ulang perintah sampai 3x kalau gagal (mis. hiccup jaringan)
retry() {
  local n=0 max=3 delay=5
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge "$max" ]; then
      return 1
    fi
    echo "  ...gagal, retry ($n/$max) dalam ${delay}s"
    sleep "$delay"
  done
}

# Jalankan ffmpeg dengan progress detail (waktu/frame/bitrate tertulis tiap detik),
# PLUS heartbeat tiap 60 detik agar GitHub Actions tidak menganggap step "hang"
# (GitHub otomatis membatalkan step yang diam tanpa output selama ~10 menit).
run_ffmpeg_with_heartbeat() {
  local logfile
  logfile=$(mktemp)

  ffmpeg -y -hide_banner -loglevel error -stats "$@" >"$logfile" 2>&1 &
  local ffmpeg_pid=$!

  local elapsed=0
  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    sleep 10
    elapsed=$((elapsed + 10))
    # Tulis baris progress terakhir dari ffmpeg (kalau ada) tiap 10 detik
    tail -n 1 "$logfile" | tr '\r' '\n' | tail -n 1
    if [ $((elapsed % 60)) -eq 0 ]; then
      echo "  ...masih memproses (${elapsed}s berjalan)"
    fi
  done

  wait "$ffmpeg_pid"
  local rc=$?
  rm -f "$logfile"
  return $rc
}

# Kirim callback webhook, PLUS log http_code & body kalau gagal (untuk debugging 403/WAF/dsb).
# Return 0 kalau http_code == 200, selain itu return 1 (dipakai oleh retry()).
# Menerima payload JSON siap-pakai sebagai argumen (rekap satu batch, bukan per-video).
send_webhook() {
  local payload="$1"
  local body_file
  body_file=$(mktemp /tmp/webhook_body_XXXX)

  local http_code
  http_code=$(curl -sS -L -X POST \
    "https://www.parokitulungagung.org/r2-video-webhook.php" \
    -H "Content-Type: application/json" \
    -H "X-Webhook-Secret: $WEBHOOK_SECRET" \
    -A "ParokiTulungagung-VideoWebhook/1.0" \
    -d "$payload" \
    -o "$body_file" -w "%{http_code}") || true

  if [ "$http_code" = "200" ]; then
    rm -f "$body_file"
    return 0
  fi

  echo "  ⚠ Webhook HTTP $http_code. Response body (maks 500 char):"
  head -c 500 "$body_file"
  echo ""
  rm -f "$body_file"
  return 1
}

# ── 1) Scan sendiri semua object video pending untuk album ini ──
$AWS s3api list-objects-v2 \
  --bucket "$R2_BUCKET" --prefix "$STAGING_PREFIX" \
  --query 'Contents[].Key' --output json > staging_keys.json

COUNT=$(jq 'length' staging_keys.json)
echo "Total video ditemukan di staging: $COUNT"

if [ "$COUNT" -eq 0 ]; then
  echo "Tidak ada video pending untuk album ini, selesai."
  exit 0
fi

OK=0
FAIL=0
PROCESSED_KEYS=()   # menampung target_key yang sukses, dipakai untuk payload webhook di akhir batch

# ── 2) Proses satu-per-satu, BERURUTAN ──
for i in $(seq 0 $((COUNT - 1))); do
  STAGING_KEY=$(jq -r ".[$i]" staging_keys.json)
  RELPATH="${STAGING_KEY#"$STAGING_PREFIX"}"
  TARGET_KEY="${TARGET_PREFIX}${RELPATH}"
  POSTER_KEY="${TARGET_KEY%.*}.webp"

  echo "── [$((i + 1))/$COUNT] $STAGING_KEY → $TARGET_KEY ──"

  SRC="/tmp/src_$i"
  OUT="/tmp/out_$i.mp4"
  POSTER="/tmp/poster_$i.webp"

  if retry $AWS s3 cp --only-show-errors \
       "s3://$R2_BUCKET/$STAGING_KEY" "$SRC"; then

    # Kompresi: 540p, CRF 29, preset slow, capped bitrate <850k (file kecil & jernih)
    if run_ffmpeg_with_heartbeat -i "$SRC" \
         -c:v libx264 -crf 29 -preset slow \
         -maxrate 850k -bufsize 1700k \
         -pix_fmt yuv420p \
         -vf "scale='min(960,iw)':'min(540,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2" \
         -c:a aac -b:a 64k -ac 1 \
         -movflags +faststart \
         "$OUT"; then

      if retry $AWS s3 cp --only-show-errors \
           "$OUT" "s3://$R2_BUCKET/$TARGET_KEY" \
           --content-type "video/mp4"; then

        # Poster/thumbnail dari frame ~1 detik
        if ffmpeg -y -hide_banner -loglevel error -ss 00:00:01 -i "$OUT" -frames:v 1 \
             -vf "scale='min(960,iw)':-2" "$POSTER"; then
          retry $AWS s3 cp --only-show-errors \
            "$POSTER" "s3://$R2_BUCKET/$POSTER_KEY" \
            --content-type "image/webp" || echo "  ⚠ Poster gagal diupload, dilanjut tanpa poster."
        else
          echo "  ⚠ Gagal membuat poster, dilanjut tanpa poster."
        fi

        # Hapus dari staging setelah sukses
        retry $AWS s3 rm "s3://$R2_BUCKET/$STAGING_KEY" || \
          echo "  ⚠ Gagal hapus dari staging (video sudah kepindah ke target)."

        echo "✓ Berhasil diproses: $TARGET_KEY"
        OK=$((OK + 1))
        PROCESSED_KEYS+=("$TARGET_KEY")

      else
        echo "❌ Gagal: upload hasil kompresi ke target untuk $STAGING_KEY"
        FAIL=$((FAIL + 1))
      fi
    else
      echo "❌ Gagal: ffmpeg compress error pada $STAGING_KEY"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "❌ Gagal: Download dari staging error pada $STAGING_KEY"
    FAIL=$((FAIL + 1))
  fi

  rm -f "$SRC" "$OUT" "$POSTER"
done

echo ""
echo "════════════════════════════════════"
echo " Ringkasan: $OK berhasil, $FAIL gagal, dari total $COUNT video."
echo "════════════════════════════════════"

# ── Callback webhook SATU KALI untuk seluruh batch (bukan per-video) ──
# Hanya dikirim kalau minimal ada 1 video yang berhasil diproses.
if [ -n "${WEBHOOK_SECRET:-}" ] && [ "$OK" -gt 0 ]; then
  echo "Mengirim callback webhook ke website (rekap $OK video)..."

  # Susun array JSON dari daftar target_key yang sukses, aman terhadap karakter spesial (spasi, kutip, dll)
  TARGET_KEYS_JSON=$(printf '%s\n' "${PROCESSED_KEYS[@]}" | jq -R . | jq -s .)

  PAYLOAD=$(jq -n \
    --arg album "$ALBUM" \
    --argjson count "$OK" \
    --argjson keys "$TARGET_KEYS_JSON" \
    '{album: $album, status: "done", processed_count: $count, target_keys: $keys}')

  if retry send_webhook "$PAYLOAD"; then
    echo "  ✓ Callback berhasil."
  else
    echo "  ⚠ Callback webhook gagal (tidak fatal)."
  fi
fi

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
