## dnsBrute(min)

Low-resource, Dockerized static + dynamic subdomain brute-forcing and resolution using shuffledns, massdns, and dnsgen. Designed to run within strict CPU/IO limits (e.g., Railway free tier) by batching, sleeping between batches, and using low CPU/IO priority.

### Features
- Static brute-force via SecLists `dns-Jhaddix.txt`
- Optional dynamic permutations using `dnsgen`
- Resolution using `shuffledns` + `massdns`
- Batching with `split`, sleep between batches, and `nice` + `ionice`
- Configurable limits via environment variables
- Outputs per-domain under `/app/out/<domain>` with a summary

### Tools Installed in Container
- Base: `debian:bookworm-slim`
- Go 1.22+ (for `shuffledns`)
- `massdns` built from source
- `dnsgen` (Python)
- `curl`, `git`, `make`, `gcc`, `coreutils`, `time`, `procps`, `util-linux`
- Resolvers from `trickest/resolvers` -> `/root/resolvers.txt`
- SecLists static wordlist -> `/app/wordlists/static.txt`

### Environment Variables
- `DOMAIN` (alt: CLI arg): target domain
- `THREADS` (default `3`)
- `BATCH_LINES` (default `20000`)
- `SLEEP_SEC` (default `5`)
- `ENABLE_DYNAMIC` (default `0`)
- `RESOLVERS` (default `/root/resolvers.txt`)
- `DNSGEN_WORDLIST` (optional)
- `MAX_RECORDS` (default `0` = no limit per phase)
- `RUN_TIMEOUT_SEC` (default `0` = unlimited)

### Output Structure
```
/app/out/<domain>/
  ├── <domain>.wordlist
  ├── <domain>.dns_brute
  ├── <domain>.dns_gen      # only if dynamic enabled
  └── summary.txt
```

### Local Run
Build:

```bash
docker build -t dnsbrute-min .
```

Run (static only):

```bash
docker run --rm -e DOMAIN=example.com -v $(pwd)/out:/app/out dnsbrute-min
```

Run (with dynamic permutations):

```bash
docker run --rm -e DOMAIN=example.com -e ENABLE_DYNAMIC=1 -v $(pwd)/out:/app/out dnsbrute-min
```

Tuning for low resources:

```bash
docker run --rm \
  -e DOMAIN=example.com \
  -e THREADS=2 -e BATCH_LINES=10000 -e SLEEP_SEC=8 \
  -v $(pwd)/out:/app/out dnsbrute-min
```

Optional timeout:

```bash
docker run --rm -e DOMAIN=example.com -e RUN_TIMEOUT_SEC=3600 -v $(pwd)/out:/app/out dnsbrute-min
```

### Railway Deployment
This repo works out-of-the-box on Railway.

1. Push to GitHub and create a new Railway project from the repo.
2. Railway will build the Docker image using the `Dockerfile`.
3. Configure variables in the Railway service settings:
   - `DOMAIN` (required)
   - Optional: `THREADS`, `BATCH_LINES`, `SLEEP_SEC`, `ENABLE_DYNAMIC`, `RUN_TIMEOUT_SEC`
4. Deploy; outputs will be stored in the container under `/app/out/<domain>`. Add a Volume (optional) and mount it at `/app/out` to persist results.

### Notes
- `resolvers.txt` is updated during image build. You can override with `RESOLVERS`.
- `dnsgen` works without a helper list; pass `DNSGEN_WORDLIST` if you want to use a custom list.

### Legal & Responsible Use
This tool is for security testing with explicit authorization. Only scan systems you own or have written permission to test. You are solely responsible for complying with laws, terms of service, and provider AUPs.# dnsBruteforce
