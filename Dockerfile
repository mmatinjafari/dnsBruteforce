# syntax=docker/dockerfile:1
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    GOPATH=/root/go \
    PATH=/usr/local/go/bin:/root/go/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash gawk git curl ca-certificates build-essential make gcc pkg-config \
    python3 python3-pip python3-venv coreutils time procps util-linux \
    libldns-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Go
RUN curl --retry 3 -fsSL https://go.dev/dl/go1.22.5.linux-amd64.tar.gz | tar -C /usr/local -xz

# Build massdns
RUN git clone --depth=1 https://github.com/blechschmidt/massdns /opt/massdns \
    && make -C /opt/massdns \
    && ln -s /opt/massdns/bin/massdns /usr/local/bin/massdns \
    && rm -rf /opt/massdns

# Install shuffledns
RUN go install github.com/projectdiscovery/shuffledns/cmd/shuffledns@latest

# Install dnsgen
RUN pip3 install --no-cache-dir --upgrade pip \
    && pip3 install --no-cache-dir dnsgen

# Download resolvers
RUN curl --retry 3 -fsSL https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt -o /root/resolvers.txt \
    && test -s /root/resolvers.txt

# Download SecLists wordlist
RUN mkdir -p /app/wordlists && \
    curl --retry 3 -fsSL https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/DNS/dns-Jhaddix.txt \
    -o /app/wordlists/static.txt && \
    test -s /app/wordlists/static.txt

WORKDIR /app
COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh

VOLUME ["/app/out"]

ENTRYPOINT ["/app/run.sh"]
