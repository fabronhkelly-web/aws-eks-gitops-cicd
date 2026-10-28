import pytest

from app import app as flask_app


@pytest.fixture()
def client():
    flask_app.config.update(TESTING=True)
    return flask_app.test_client()


def test_root_returns_hello_world(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.data.decode() == "Hello, World!"


def test_healthz(client):
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_info_reports_pod_and_version(client):
    body = client.get("/info").get_json()
    assert set(body) == {"version", "pod"}
