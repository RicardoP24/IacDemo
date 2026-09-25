#!/usr/bin/env bash
# One-time local setup: SSH key pair for controller -> agent, random admin password.
# Nothing generated here is committed (see .gitignore).
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p secrets
if [ ! -f secrets/agent_ssh_key ]; then
    ssh-keygen -t ed25519 -N "" -C "jenkins-agent" -f secrets/agent_ssh_key >/dev/null
    echo "Generated secrets/agent_ssh_key"
fi

if [ ! -f .env ]; then
    password=$(openssl rand -base64 24)
    {
        echo "JENKINS_ADMIN_PASSWORD=${password}"
        echo "AGENT_SSH_PUBKEY=$(cat secrets/agent_ssh_key.pub)"
    } > .env
    chmod 600 .env
    echo "Wrote .env - Jenkins admin password: ${password}"
fi

echo "Next: docker compose up -d --build   (UI on http://localhost:8080)"
