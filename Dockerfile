FROM ubuntu:latest

# Install dependencies for nvm
RUN apt-get update && apt-get install -y curl build-essential ca-certificates tini && rm -rf /var/lib/apt/lists/*

COPY setup-host-user.sh /usr/local/bin/setup-host-user.sh
RUN chmod 755 /usr/local/bin/setup-host-user.sh

# Install nvm, node and npm
ENV NVM_DIR=/root/.nvm
ENV NODE_VERSION=v22

RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
RUN /bin/bash -c "source $NVM_DIR/nvm.sh && nvm install $NODE_VERSION && nvm use $NODE_VERSION && nvm alias default $NODE_VERSION"

WORKDIR /sandbox
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["tail", "-f", "/dev/null"]
