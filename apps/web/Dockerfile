# syntax=docker/dockerfile:1

# Unprivileged nginx (listens on 8080, runs as uid 101), pinned by digest.
FROM nginxinc/nginx-unprivileged:1.30-alpine@sha256:4714e0b1b2577eaa1a6131d07c958b67f0eb68e6d0521e90c6e5287db8cf0bc5

# Files owned by root and not writable by the runtime user.
COPY --chown=root:root nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --chown=root:root public/ /usr/share/nginx/html/

# Defaults for local runs; the Helm chart overrides both per tenant.
ENV TENANT=demo \
    API_UPSTREAM=api:8080

USER 101
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
