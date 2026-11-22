import logging
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy import event, func, select, text
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy import create_engine
from starlette.middleware.sessions import SessionMiddleware

from . import config
from .config import Settings
from .models import PRIORITIES, STATUSES, Attachment, Base, Ticket, User, next_status
from .security import hash_password, new_csrf_token, verify_password
from .storage import LocalStorage, build_storage

logging.basicConfig(level=logging.INFO, format='{"time":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}')
log = logging.getLogger("ticketdesk")
BASE_DIR = Path(__file__).parent


def use_current_db_password(engine, secret_arn: str) -> None:
    """RDS rotates the managed master password (every 7 days by default). Read the current value for every
    new pooled connection so the app keeps working after a rotation without a restart."""

    @event.listens_for(engine, "do_connect")
    def _fresh_db_password(dialect, conn_rec, cargs, cparams):
        cparams["password"] = config._secret(secret_arn)["password"]


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    engine = create_engine(settings.database_url, pool_pre_ping=True)
    if settings.db_secret_arn:
        use_current_db_password(engine, settings.db_secret_arn)
    SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)
    storage = build_storage(settings)
    templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        startup()
        yield

    app = FastAPI(title="TicketDesk", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")
    app.add_middleware(
        SessionMiddleware,
        secret_key=settings.session_secret,
        session_cookie="ticketdesk_session",
        https_only=settings.secure_cookies,
        same_site="lax",
        max_age=8 * 3600,
    )

    # ---------- startup: wait for DB, create tables, seed users ----------
    def startup() -> None:
        for attempt in range(30):
            try:
                Base.metadata.create_all(engine)
                break
            except Exception as exc:  # DB may still be starting
                log.warning("database not ready (%s), retry %s/30", type(exc).__name__, attempt + 1)
                time.sleep(2)
        else:
            raise RuntimeError("database unavailable")
        with SessionLocal() as db:
            for username, pwd, role in (
                ("admin", settings.admin_password, "admin"),
                ("user", settings.user_password, "user"),
            ):
                existing = db.scalar(select(User).where(User.username == username))
                if not existing:
                    db.add(User(username=username, password_hash=hash_password(pwd), role=role))
                elif not verify_password(pwd, existing.password_hash):
                    # The secret is the source of truth: rotating it + restarting the app rotates the login
                    existing.password_hash = hash_password(pwd)
                    log.info("seed password updated from secret for user=%s", username)
            db.commit()
        log.info("startup complete")

    # ---------- dependencies ----------
    def get_db():
        with SessionLocal() as db:
            yield db

    def current_user(request: Request, db: Session = Depends(get_db)) -> User:
        uid = request.session.get("uid")
        user = db.get(User, uid) if uid else None
        if not user:
            raise HTTPException(status_code=303, headers={"Location": "/login"})
        return user

    async def csrf_protect(request: Request) -> None:
        form = await request.form()
        token = request.session.get("csrf")
        if not token or form.get("csrf") != token:
            raise HTTPException(status_code=403, detail="Invalid CSRF token")

    def render(request: Request, name: str, **ctx):
        if not request.session.get("csrf"):
            request.session["csrf"] = new_csrf_token()
        ctx.update(csrf=request.session["csrf"], statuses=STATUSES, priorities=PRIORITIES)
        return templates.TemplateResponse(request, name, ctx)

    def visible_tickets(db: Session, user: User):
        q = select(Ticket).order_by(Ticket.id.desc())
        if user.role != "admin":
            q = q.where(Ticket.created_by == user.id)
        return q

    def get_ticket_or_404(db: Session, user: User, ticket_id: int) -> Ticket:
        ticket = db.get(Ticket, ticket_id)
        if not ticket or (user.role != "admin" and ticket.created_by != user.id):
            raise HTTPException(status_code=404, detail="Ticket not found")
        return ticket

    # ---------- routes ----------
    @app.get("/health")
    def health():
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            return {"status": "ok", "database": "up"}
        except Exception:
            return JSONResponse({"status": "degraded", "database": "down"}, status_code=503)

    @app.get("/")
    def index(request: Request):
        return RedirectResponse("/dashboard" if request.session.get("uid") else "/login", status_code=303)

    @app.get("/login")
    def login_page(request: Request):
        return render(request, "login.html", error=None, username="")

    @app.post("/login", dependencies=[Depends(csrf_protect)])
    def login(request: Request, username: str = Form(...), password: str = Form(...), db: Session = Depends(get_db)):
        user = db.scalar(select(User).where(User.username == username))
        if not user or not verify_password(password, user.password_hash):
            log.warning("failed login for %s", username[:32])
            return render(request, "login.html", error="Invalid username or password", username=username[:64])
        csrf = request.session.get("csrf")
        request.session.clear()
        request.session.update(uid=user.id, csrf=csrf or new_csrf_token())
        log.info("login ok user=%s", user.username)
        return RedirectResponse("/dashboard", status_code=303)

    @app.post("/logout", dependencies=[Depends(csrf_protect)])
    def logout(request: Request):
        request.session.clear()
        return RedirectResponse("/login", status_code=303)

    @app.get("/dashboard")
    def dashboard(request: Request, user: User = Depends(current_user), db: Session = Depends(get_db)):
        q = select(Ticket.status, func.count()).group_by(Ticket.status)
        if user.role != "admin":
            q = q.where(Ticket.created_by == user.id)
        counts = {s: 0 for s in STATUSES}
        counts.update(dict(db.execute(q).all()))
        recent = db.scalars(visible_tickets(db, user).limit(6)).all()
        return render(request, "dashboard.html", user=user, counts=counts, total=sum(counts.values()), recent=recent,
                      active="dashboard")

    @app.get("/api/dashboard")
    def dashboard_api(user: User = Depends(current_user), db: Session = Depends(get_db)):
        q = select(Ticket.status, func.count()).group_by(Ticket.status)
        if user.role != "admin":
            q = q.where(Ticket.created_by == user.id)
        counts = {s: 0 for s in STATUSES}
        counts.update(dict(db.execute(q).all()))
        return {"counts": counts, "total": sum(counts.values())}

    @app.get("/tickets")
    def list_tickets(request: Request, status: str = "", user: User = Depends(current_user), db: Session = Depends(get_db)):
        q = visible_tickets(db, user)
        if status in STATUSES:
            q = q.where(Ticket.status == status)
        return render(request, "tickets.html", user=user, tickets=db.scalars(q).all(), filter=status, active="tickets")

    @app.post("/tickets", dependencies=[Depends(csrf_protect)])
    def create_ticket(
        title: str = Form(..., max_length=200),
        description: str = Form("", max_length=5000),
        priority: str = Form("Medium"),
        user: User = Depends(current_user),
        db: Session = Depends(get_db),
    ):
        if not title.strip() or priority not in PRIORITIES:
            raise HTTPException(status_code=422, detail="Invalid ticket")
        ticket = Ticket(title=title.strip(), description=description, priority=priority, created_by=user.id)
        db.add(ticket)
        db.commit()
        log.info("ticket created id=%s by=%s", ticket.id, user.username)
        return RedirectResponse(f"/tickets/{ticket.id}", status_code=303)

    @app.get("/tickets/{ticket_id}")
    def ticket_detail(request: Request, ticket_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
        ticket = get_ticket_or_404(db, user, ticket_id)
        return render(
            request, "ticket.html", user=user, ticket=ticket, next_status=next_status(ticket.status), active="tickets",
            error=request.query_params.get("error"),
        )

    @app.post("/tickets/{ticket_id}/status", dependencies=[Depends(csrf_protect)])
    def update_status(ticket_id: int, status: str = Form(...), user: User = Depends(current_user), db: Session = Depends(get_db)):
        if user.role != "admin":
            raise HTTPException(status_code=403, detail="Only admins can change ticket status")
        ticket = get_ticket_or_404(db, user, ticket_id)
        if status != next_status(ticket.status):
            raise HTTPException(status_code=422, detail=f"Invalid transition {ticket.status} -> {status}")
        ticket.status = status
        db.commit()
        log.info("ticket %s -> %s by %s", ticket.id, status, user.username)
        return RedirectResponse(f"/tickets/{ticket.id}", status_code=303)

    @app.post("/tickets/{ticket_id}/attachments", dependencies=[Depends(csrf_protect)])
    async def upload_attachment(
        ticket_id: int, file: UploadFile = File(...), user: User = Depends(current_user), db: Session = Depends(get_db)
    ):
        ticket = get_ticket_or_404(db, user, ticket_id)
        name = file.filename or "file"
        if not name.lower().endswith(settings.allowed_extensions):
            return RedirectResponse(f"/tickets/{ticket.id}?error=File+type+not+allowed", status_code=303)
        data = await file.read(settings.max_upload_bytes + 1)
        if len(data) > settings.max_upload_bytes:
            return RedirectResponse(f"/tickets/{ticket.id}?error=File+too+large+(max+5MB)", status_code=303)
        key = storage.put(ticket.id, name, data, file.content_type or "application/octet-stream")
        db.add(Attachment(ticket_id=ticket.id, filename=name[:255], storage_key=key,
                          content_type=file.content_type or "application/octet-stream", size=len(data)))
        db.commit()
        log.info("attachment stored ticket=%s key=%s size=%s", ticket.id, key, len(data))
        return RedirectResponse(f"/tickets/{ticket.id}", status_code=303)

    @app.get("/attachments/{attachment_id}")
    def download_attachment(attachment_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
        att = db.get(Attachment, attachment_id)
        if not att:
            raise HTTPException(status_code=404)
        get_ticket_or_404(db, user, att.ticket_id)
        url = storage.url(att.storage_key, att.filename)
        if url:
            return RedirectResponse(url, status_code=303)
        assert isinstance(storage, LocalStorage)
        return FileResponse(storage.local_path(att.storage_key), filename=att.filename)

    @app.exception_handler(HTTPException)
    async def http_exc(request: Request, exc: HTTPException):
        if exc.status_code == 303:
            return RedirectResponse(exc.headers["Location"], status_code=303)
        return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)

    return app


def get_app() -> FastAPI:  # uvicorn --factory ticketdesk.main:get_app
    return create_app()
