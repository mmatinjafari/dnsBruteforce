#!/usr/bin/env bash
set -euo pipefail

trap 'echo "SIGTERM received, exiting..."; exit 143' TERM

# Defaults (low resource friendly)
THREADS="${THREADS:-3}"
BATCH_LINES="${BATCH_LINES:-20000}"
SLEEP_SEC="${SLEEP_SEC:-5}"
ENABLE_DYNAMIC="${ENABLE_DYNAMIC:-0}"
RESOLVERS="${RESOLVERS:-/root/resolvers.txt}"
DNSGEN_WORDLIST="${DNSGEN_WORDLIST:-}"
MAX_RECORDS="${MAX_RECORDS:-0}"
RUN_TIMEOUT_SEC="${RUN_TIMEOUT_SEC:-0}"

DOMAIN="${1:-${DOMAIN:-}}"
if [[ -z "$DOMAIN" ]]; then
  echo "Usage: ./run.sh <domain> or set DOMAIN env"
  exit 1
fi

OUTDIR="/app/out/$DOMAIN"
mkdir -p "$OUTDIR"

log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }

cleanup_tmp() {
  rm -f "$OUTDIR"/${DOMAIN}_part_* || true
  rm -f "$OUTDIR"/${DOMAIN}_gen_part_* || true
}
trap cleanup_tmp EXIT

log "Starting scan for $DOMAIN"
log "THREADS=$THREADS BATCH_LINES=$BATCH_LINES SLEEP_SEC=$SLEEP_SEC ENABLE_DYNAMIC=$ENABLE_DYNAMIC"

# Clean old files
rm -f "$OUTDIR/$DOMAIN.wordlist" "$OUTDIR/$DOMAIN.dns_brute" "$OUTDIR/$DOMAIN.dns_gen" "$OUTDIR/summary.txt"

start_ts=$(date +%s)

# Build static wordlist (.domain appended)
awk -v domain="$DOMAIN" '{print $0"."domain}' /app/wordlists/static.txt > "$OUTDIR/$DOMAIN.wordlist"
if [[ "$MAX_RECORDS" != "0" ]]; then
  head -n "$MAX_RECORDS" "$OUTDIR/$DOMAIN.wordlist" > "$OUTDIR/tmp" && mv "$OUTDIR/tmp" "$OUTDIR/$DOMAIN.wordlist"
fi

# Prepare timeout wrapper if requested
maybe_timeout() {
  if [[ "$RUN_TIMEOUT_SEC" != "0" ]]; then
    timeout --preserve-status "$RUN_TIMEOUT_SEC" "$@"
  else
    "$@"
  fi
}

# Split into batches
split -l "$BATCH_LINES" "$OUTDIR/$DOMAIN.wordlist" "$OUTDIR/${DOMAIN}_part_" || true

# Static resolution (shuffledns + massdns)
static_batches=0
for part in "$OUTDIR"/${DOMAIN}_part_*; do
  [[ -e "$part" ]] || break
  static_batches=$((static_batches+1))
  log ">> Static batch: $(basename "$part")"
  maybe_timeout nice -n 10 ionice -c3 \
    shuffledns -list "$part" -d "$DOMAIN" \
      -r "$RESOLVERS" -m "$(command -v massdns)" -t "$THREADS" -silent \
    | tee -a "$OUTDIR/$DOMAIN.dns_brute" >/dev/null || true
  sleep "$SLEEP_SEC"
done

# Dynamic phase (dnsgen) optional
dyn_batches=0
if [[ "$ENABLE_DYNAMIC" == "1" ]]; then
  log "Generating permutations via dnsgen"
  if [[ -n "$DNSGEN_WORDLIST" && -f "$DNSGEN_WORDLIST" ]]; then
    maybe_timeout dnsgen -w "$DNSGEN_WORDLIST" "$OUTDIR/$DOMAIN.dns_brute" > "$OUTDIR/$DOMAIN.dns_gen"
  else
    maybe_timeout dnsgen "$OUTDIR/$DOMAIN.dns_brute" > "$OUTDIR/$DOMAIN.dns_gen"
  fi
  if [[ "$MAX_RECORDS" != "0" ]]; then
    head -n "$MAX_RECORDS" "$OUTDIR/$DOMAIN.dns_gen" > "$OUTDIR/tmp" && mv "$OUTDIR/tmp" "$OUTDIR/$DOMAIN.dns_gen"
  fi

  split -l "$BATCH_LINES" "$OUTDIR/$DOMAIN.dns_gen" "$OUTDIR/${DOMAIN}_gen_part_" || true
  for part in "$OUTDIR"/${DOMAIN}_gen_part_*; do
    [[ -e "$part" ]] || break
    dyn_batches=$((dyn_batches+1))
    log ">> Dynamic batch: $(basename "$part")"
    maybe_timeout nice -n 10 ionice -c3 \
      shuffledns -list "$part" -d "$DOMAIN" \
        -r "$RESOLVERS" -m "$(command -v massdns)" -t "$THREADS" -silent \
      | tee -a "$OUTDIR/$DOMAIN.dns_brute" >/dev/null || true
    sleep "$SLEEP_SEC"
  done
fi

# Deduplicate results
if [[ -f "$OUTDIR/$DOMAIN.dns_brute" ]]; then
  sort -u "$OUTDIR/$DOMAIN.dns_brute" -o "$OUTDIR/$DOMAIN.dns_brute"
else
  touch "$OUTDIR/$DOMAIN.dns_brute"
fi

end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

# Summary
{
  echo "Domain: $DOMAIN"
  echo "Threads: $THREADS"
  echo "Batch size: $BATCH_LINES"
  echo "Sleep between batches (sec): $SLEEP_SEC"
  echo "Dynamic enabled: $ENABLE_DYNAMIC"
  echo "Static batches: $static_batches"
  echo "Dynamic batches: $dyn_batches"
  echo "Resolvers: $RESOLVERS"
  echo "Records resolved: $(wc -l < "$OUTDIR/$DOMAIN.dns_brute" 2>/dev/null || echo 0)"
  echo "Elapsed seconds: $elapsed"
} > "$OUTDIR/summary.txt"

log "Done. Resolved count: $(wc -l < "$OUTDIR/$DOMAIN.dns_brute" 2>/dev/null || echo 0)"
log "Output saved to $OUTDIR"

