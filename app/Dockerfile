# syntax=docker/dockerfile:1
FROM python:3.12-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
# Pick up Debian security fixes released after the base image was built (e.g. zlib CVE-2026-85091)
RUN apt-get update && apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --create-home appuser
COPY --from=build /install /usr/local
WORKDIR /srv
COPY ticketdesk ./ticketdesk
# Do not depend on host file modes (files checked out/extracted as 0600 are unreadable by appuser)
RUN chmod -R a+rX,go-w /srv/ticketdesk
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health').status==200 else 1)"
CMD ["uvicorn", "ticketdesk.main:get_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
