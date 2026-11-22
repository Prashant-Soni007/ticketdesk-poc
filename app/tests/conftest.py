import re

import pytest
from fastapi.testclient import TestClient

from ticketdesk.config import Settings
from ticketdesk.main import create_app


@pytest.fixture()
def app(tmp_path):
    settings = Settings(
        database_url=f"sqlite:///{tmp_path}/test.db",
        session_secret="test-secret",
        admin_password="adminpass1!",
        user_password="userpass1!",
        upload_dir=str(tmp_path / "uploads"),
    )
    return create_app(settings)


@pytest.fixture()
def client(app):
    with TestClient(app, follow_redirects=False) as c:
        yield c


def csrf_of(client, path="/login"):
    html = client.get(path).text
    return re.search(r'name="csrf" value="([^"]+)"', html).group(1)


def login(client, username="user", password="userpass1!"):
    token = csrf_of(client)
    return client.post("/login", data={"username": username, "password": password, "csrf": token})
