import pytest

from app import create_app


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("TENANT", "client-test")
    monkeypatch.setenv("APP_VERSION", "1.2.3")
    app = create_app()
    app.testing = True
    return app.test_client()


def test_healthz(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_info_reports_tenant_and_version(client):
    body = client.get("/api/info").get_json()
    assert body["tenant"] == "client-test"
    assert body["version"] == "1.2.3"
    assert body["app"] == "api"


def test_security_headers(client):
    response = client.get("/api/info")
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["Cache-Control"] == "no-store"


def test_unknown_route_returns_404(client):
    assert client.get("/admin").status_code == 404
