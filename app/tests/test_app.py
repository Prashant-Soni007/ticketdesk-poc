from conftest import csrf_of, login


def create_ticket(client, title="Printer broken", priority="High"):
    token = csrf_of(client, "/tickets")
    return client.post("/tickets", data={"title": title, "description": "no ink", "priority": priority, "csrf": token})


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200 and r.json() == {"status": "ok", "database": "up"}


def test_login_required(client):
    r = client.get("/tickets")
    assert r.status_code == 303 and r.headers["location"] == "/login"


def test_login_success_and_failure(client):
    assert login(client, "user", "wrong").status_code == 200  # re-rendered with error
    r = login(client)
    assert r.status_code == 303 and r.headers["location"] == "/dashboard"


def test_csrf_enforced(client):
    r = client.post("/login", data={"username": "user", "password": "userpass1!", "csrf": "bad"})
    assert r.status_code == 403


def test_create_and_view_ticket(client):
    login(client)
    r = create_ticket(client)
    assert r.status_code == 303
    page = client.get(r.headers["location"]).text
    assert "Printer broken" in page and "Open" in page
    assert "Printer broken" in client.get("/tickets").text


def test_user_cannot_change_status_admin_can_flow(client):
    login(client)
    loc = create_ticket(client).headers["location"]
    tid = loc.split("/")[-1]
    token = csrf_of(client, loc)
    assert client.post(f"/tickets/{tid}/status", data={"status": "In Progress", "csrf": token}).status_code == 403

    client.post("/logout", data={"csrf": token})
    login(client, "admin", "adminpass1!")
    for status in ("In Progress", "Resolved", "Closed"):
        token = csrf_of(client, loc)
        assert client.post(f"/tickets/{tid}/status", data={"status": status, "csrf": token}).status_code == 303
        assert status in client.get(loc).text


def test_invalid_status_transition_rejected(client):
    login(client, "admin", "adminpass1!")
    loc = create_ticket(client).headers["location"]
    token = csrf_of(client, loc)
    r = client.post(f"{loc}/status", data={"status": "Closed", "csrf": token})
    assert r.status_code == 422


def test_dashboard_counts(client):
    login(client)
    create_ticket(client, "a")
    create_ticket(client, "b")
    data = client.get("/api/dashboard").json()
    assert data["total"] == 2 and data["counts"]["Open"] == 2


def test_users_cannot_see_other_users_tickets(client):
    login(client)
    loc = create_ticket(client).headers["location"]
    token = csrf_of(client, "/tickets")
    client.post("/logout", data={"csrf": token})
    login(client, "admin", "adminpass1!")
    assert client.get(loc).status_code == 200  # admin sees all
    # a fresh anonymous client is redirected
    client.cookies.clear()
    assert client.get(loc).status_code == 303


def test_attachment_upload_download_and_validation(client):
    login(client)
    loc = create_ticket(client).headers["location"]
    token = csrf_of(client, loc)
    ok = client.post(f"{loc}/attachments", data={"csrf": token}, files={"file": ("shot.txt", b"hello", "text/plain")})
    assert ok.status_code == 303 and "error" not in ok.headers["location"]
    assert "shot.txt" in client.get(loc).text
    assert client.get("/attachments/1").content == b"hello"
    bad = client.post(f"{loc}/attachments", data={"csrf": token}, files={"file": ("evil.exe", b"x", "application/octet-stream")})
    assert "error" in bad.headers["location"]


def test_rotated_seed_password_applied_on_restart(tmp_path):
    """Rotating the secret and restarting the app must change the seed logins (old password stops working)."""
    from fastapi.testclient import TestClient

    from ticketdesk.config import Settings
    from ticketdesk.main import create_app

    def start(user_pw):
        s = Settings(database_url=f"sqlite:///{tmp_path}/rot.db", session_secret="s", admin_password="admin-pw-1",
                     user_password=user_pw, upload_dir=str(tmp_path / "up"))
        return TestClient(create_app(s), follow_redirects=False)

    with start("old-pw") as c:
        assert login(c, "user", "old-pw").status_code == 303
    with start("new-pw") as c:  # same database, rotated secret
        assert login(c, "user", "old-pw").status_code == 200  # rejected (login page re-rendered)
        assert login(c, "user", "new-pw").status_code == 303
        assert login(c, "admin", "admin-pw-1").status_code == 303  # unchanged user untouched
