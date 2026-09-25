# syntax=docker/dockerfile:1

# Jenkins SSH build agent with the full DevSecOps toolchain.
# Every binary is pinned and its SHA-256 verified before it lands in the image.
FROM jenkins/ssh-agent:9.0.0-jdk21@sha256:4609eba9f086fc7321de8e40e217601158280d5bd21160b9ed6e6e5218936c1c

ARG TERRAFORM_VERSION=1.15.8
ARG KUBECTL_VERSION=1.35.9
ARG HELM_VERSION=4.3.0
ARG TRIVY_VERSION=0.74.0
ARG GITLEAKS_VERSION=8.30.1
# cosign v2 keeps the classic signature format verified by Kyverno.
ARG COSIGN_VERSION=2.6.5
ARG SYFT_VERSION=1.52.0
ARG HADOLINT_VERSION=2.15.1
ARG KYVERNO_VERSION=1.19.1
ARG CHECKOV_VERSION=3.3.19
ARG SEMGREP_VERSION=1.178.0

# sshd must start as root; builds run as the unprivileged "jenkins" user over SSH.
# checkov:skip=CKV_DOCKER_8: sshd needs root; pipeline steps run as the jenkins user.
# hadolint ignore=DL3002
USER root
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Base packages + Docker CLI from Docker's signed APT repository.
# The Docker daemon is the TLS-protected DinD sidecar, not the host's socket.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git gnupg jq unzip python3 python3-venv \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 fetch-verified.sh /usr/local/bin/fetch-verified

WORKDIR /tmp/tools
RUN GH=https://github.com \
    && fetch-verified https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
                      https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS \
    && unzip -q "terraform_${TERRAFORM_VERSION}_linux_amd64.zip" terraform -d /usr/local/bin \
    && fetch-verified https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl \
                      https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256 \
    && install -m 0755 kubectl /usr/local/bin/kubectl \
    && fetch-verified https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz \
                      https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz.sha256sum \
    && tar -xzf "helm-v${HELM_VERSION}-linux-amd64.tar.gz" --strip-components=1 -C /usr/local/bin linux-amd64/helm \
    && fetch-verified ${GH}/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz \
                      ${GH}/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_checksums.txt \
    && tar -xzf "trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" -C /usr/local/bin trivy \
    && fetch-verified ${GH}/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz \
                      ${GH}/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_checksums.txt \
    && tar -xzf "gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" -C /usr/local/bin gitleaks \
    && fetch-verified ${GH}/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64 \
                      ${GH}/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign_checksums.txt \
    && install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign \
    && fetch-verified ${GH}/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_amd64.tar.gz \
                      ${GH}/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_checksums.txt \
    && tar -xzf "syft_${SYFT_VERSION}_linux_amd64.tar.gz" -C /usr/local/bin syft \
    && fetch-verified ${GH}/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-x86_64 \
                      ${GH}/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/checksums.sha256 \
    && install -m 0755 hadolint-linux-x86_64 /usr/local/bin/hadolint \
    && fetch-verified ${GH}/kyverno/kyverno/releases/download/v${KYVERNO_VERSION}/kyverno-cli_v${KYVERNO_VERSION}_linux_x86_64.tar.gz \
                      ${GH}/kyverno/kyverno/releases/download/v${KYVERNO_VERSION}/checksums.txt \
    && tar -xzf "kyverno-cli_v${KYVERNO_VERSION}_linux_x86_64.tar.gz" -C /usr/local/bin kyverno

# AWS CLI v2 (TLS download; AWS also publishes a PGP signature for stricter verification).
RUN curl -fsSLo awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
    && unzip -q awscliv2.zip \
    && ./aws/install \
    && rm -rf /tmp/tools

# Python-based scanners in an isolated virtualenv.
RUN python3 -m venv /opt/pytools \
    && /opt/pytools/bin/pip install --no-cache-dir "checkov==${CHECKOV_VERSION}" "semgrep==${SEMGREP_VERSION}" \
    && ln -s /opt/pytools/bin/checkov /opt/pytools/bin/semgrep /usr/local/bin/

WORKDIR /home/jenkins
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/22"]
