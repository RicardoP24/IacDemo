"""Minimal tenant-aware API.

Each tenant namespace runs its own copy of this service. The tenant name is
injected through the environment by the Helm chart, so the same image is
reused by every tenant.
"""

import os
import socket

from flask import Flask, jsonify


def create_app() -> Flask:
    app = Flask(__name__)
    tenant = os.environ.get("TENANT", "unknown")
    version = os.environ.get("APP_VERSION", "dev")

    @app.get("/healthz")
    def healthz():
        return jsonify(status="ok")

    @app.get("/api/info")
    def info():
        return jsonify(tenant=tenant, app="api", version=version, pod=socket.gethostname())

    @app.after_request
    def security_headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Cache-Control"] = "no-store"
        return response

    return app


app = create_app()
