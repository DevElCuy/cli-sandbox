FROM ubuntu:latest

# Install dependencies for nvm
RUN apt-get update && apt-get install -y curl build-essential ca-certificates tini && rm -rf /var/lib/apt/lists/*

COPY setup-host-user.sh /usr/local/bin/setup-host-user.sh
RUN chmod 755 /usr/local/bin/setup-host-user.sh



WORKDIR /sandbox
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["tail", "-f", "/dev/null"]
