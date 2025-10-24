FROM ubuntu:latest

# Install dependencies for nvm
RUN apt-get update && apt-get install -y curl build-essential ca-certificates tini
# Clean-up APT
#RUN rm -rf /var/lib/apt/lists/*

# Customize bash prompt to honor CLI sandbox hostname
RUN cat <<'EOF' >> /home/ubuntu/.bashrc
# CLI sandbox prompt override
if [[ $- == *i* ]] && [ -n "${CLI_SANDBOX_HOSTNAME-}" ] && [[ "$PS1" == *\\h* ]]; then
    PS1="${PS1//\\h/${CLI_SANDBOX_HOSTNAME}}"
fi
EOF

COPY setup-host-user.sh /usr/local/bin/setup-host-user.sh
RUN chmod 755 /usr/local/bin/setup-host-user.sh

# Create wrapper scripts for CLI tools
RUN echo '#!/bin/bash\nexport NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"\nexec npx @google/gemini-cli "$@"' > /usr/local/bin/gemini && chmod +x /usr/local/bin/gemini
RUN echo '#!/bin/bash\nexport NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"\nexec npx @openai/codex "$@"' > /usr/local/bin/codex && chmod +x /usr/local/bin/codex
RUN echo '#!/bin/bash\nexport NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"\nexec npx @anthropic-ai/claude-code "$@"' > /usr/local/bin/claude && chmod +x /usr/local/bin/claude

ENV TERM=xterm-256color

WORKDIR /sandbox
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["tail", "-f", "/dev/null"]
