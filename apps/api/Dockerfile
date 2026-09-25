# syntax=docker/dockerfile:1

# Base image pinned by digest (tags are mutable, digests are not). Same digest in both stages.

# ---- build stage: dependencies only, installed with hash verification ----
FROM python:3.13-slim@sha256:8d9d0b8bcf6506481eae4907c18f5e3e7902e629f5f6d684f9e7c32e85e3ddf0 AS build
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
COPY requirements.txt /tmp/requirements.txt
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --require-hashes -r /tmp/requirements.txt

# ---- runtime stage: no compilers, no pip cache, non-root ----
FROM python:3.13-slim@sha256:8d9d0b8bcf6506481eae4907c18f5e3e7902e629f5f6d684f9e7c32e85e3ddf0
ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /opt/venv /opt/venv
WORKDIR /app
COPY app.py .

USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"]

# /dev/shm is a tmpfs, so gunicorn heartbeats work with a read-only root filesystem.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "app:app"]
