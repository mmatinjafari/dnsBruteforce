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
TARGETS_FILE="${TARGETS_FILE:-/app/targets.txt}"

log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }

# Prepare timeout wrapper if requested
maybe_timeout() {
  if [[ "$RUN_TIMEOUT_SEC" != "0" ]]; then
    timeout --preserve-status "$RUN_TIMEOUT_SEC" "$@"
  else
    "$@"
  fi
}

run_for_domain() {
  local domain="$1"
  local outdir="/app/out/$domain"
  mkdir -p "$outdir"

  log "Starting scan for $domain"
  log "THREADS=$THREADS BATCH_LINES=$BATCH_LINES SLEEP_SEC=$SLEEP_SEC ENABLE_DYNAMIC=$ENABLE_DYNAMIC"

  # Clean old files
  rm -f "$outdir/$domain.wordlist" "$outdir/$domain.dns_brute" "$outdir/$domain.dns_gen" "$outdir/summary.txt"

  local start_ts end_ts elapsed static_batches dyn_batches
  start_ts=$(date +%s)

  # Build static wordlist (.domain appended)
  awk -v domain="$domain" '{print $0"."domain}' /app/wordlists/static.txt > "$outdir/$domain.wordlist"
  if [[ "$MAX_RECORDS" != "0" ]]; then
    head -n "$MAX_RECORDS" "$outdir/$domain.wordlist" > "$outdir/tmp" && mv "$outdir/tmp" "$outdir/$domain.wordlist"
  fi

  # Split into batches
  split -l "$BATCH_LINES" "$outdir/$domain.wordlist" "$outdir/${domain}_part_" || true

  # Static resolution
  static_batches=0
  for part in "$outdir"/${domain}_part_*; do
    [[ -e "$part" ]] || break
    static_batches=$((static_batches+1))
    log ">> Static batch: $(basename "$part")"
    maybe_timeout nice -n 10 ionice -c3 \
      shuffledns -list "$part" -d "$domain" \
        -r "$RESOLVERS" -m "$(command -v massdns)" -t "$THREADS" -silent \
      | tee -a "$outdir/$domain.dns_brute" >/dev/null || true
    sleep "$SLEEP_SEC"
  done

  # Dynamic phase (optional)
  dyn_batches=0
  if [[ "$ENABLE_DYNAMIC" == "1" ]]; then
    log "Generating permutations via dnsgen"
    if [[ -n "$DNSGEN_WORDLIST" && -f "$DNSGEN_WORDLIST" ]]; then
      maybe_timeout dnsgen -w "$DNSGEN_WORDLIST" "$outdir/$domain.dns_brute" > "$outdir/$domain.dns_gen"
    else
      maybe_timeout dnsgen "$outdir/$domain.dns_brute" > "$outdir/$domain.dns_gen"
    fi
    if [[ "$MAX_RECORDS" != "0" ]]; then
      head -n "$MAX_RECORDS" "$outdir/$domain.dns_gen" > "$outdir/tmp" && mv "$outdir/tmp" "$outdir/$domain.dns_gen"
    fi

    split -l "$BATCH_LINES" "$outdir/$domain.dns_gen" "$outdir/${domain}_gen_part_" || true
    for part in "$outdir"/${domain}_gen_part_*; do
      [[ -e "$part" ]] || break
      dyn_batches=$((dyn_batches+1))
      log ">> Dynamic batch: $(basename "$part")"
      maybe_timeout nice -n 10 ionice -c3 \
        shuffledns -list "$part" -d "$domain" \
          -r "$RESOLVERS" -m "$(command -v massdns)" -t "$THREADS" -silent \
        | tee -a "$outdir/$domain.dns_brute" >/dev/null || true
      sleep "$SLEEP_SEC"
    done
  fi

  # Deduplicate results
  if [[ -f "$outdir/$domain.dns_brute" ]]; then
    sort -u "$outdir/$domain.dns_brute" -o "$outdir/$domain.dns_brute"
  else
    touch "$outdir/$domain.dns_brute"
  fi

  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  # Summary
  {
    echo "Domain: $domain"
    echo "Threads: $THREADS"
    echo "Batch size: $BATCH_LINES"
    echo "Sleep between batches (sec): $SLEEP_SEC"
    echo "Dynamic enabled: $ENABLE_DYNAMIC"
    echo "Static batches: $static_batches"
    echo "Dynamic batches: $dyn_batches"
    echo "Resolvers: $RESOLVERS"
    echo "Records resolved: $(wc -l < "$outdir/$domain.dns_brute" 2>/dev/null || echo 0)"
    echo "Elapsed seconds: $elapsed"
  } > "$outdir/summary.txt"

  log "Done. Resolved count: $(wc -l < "$outdir/$domain.dns_brute" 2>/dev/null || echo 0)"
  log "Output saved to $outdir"

  # Cleanup temporary split files for this domain
  rm -f "$outdir"/${domain}_part_* "$outdir"/${domain}_gen_part_* || true
}

# Determine targets: file or single DOMAIN/arg
DOMAIN="${1:-${DOMAIN:-}}"

if [[ -n "$DOMAIN" ]]; then
  run_for_domain "$DOMAIN" || log "Domain failed: $DOMAIN"
  exit 0
fi

if [[ -f "$TARGETS_FILE" ]]; then
  # Read non-empty, non-comment lines and deduplicate
  mapfile -t DOMAINS < <(grep -v '^[[:space:]]*#' "$TARGETS_FILE" | sed 's/[[:space:]]//g' | sed '/^$/d' | sort -u)
  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    echo "No valid targets in $TARGETS_FILE" >&2
    exit 1
  fi
  for d in "${DOMAINS[@]}"; do
    run_for_domain "$d" || log "Domain failed: $d"
  done
  exit 0
fi

echo "Usage: ./run.sh <domain> | set DOMAIN or provide TARGETS_FILE (default /app/targets.txt)"
exit 1

