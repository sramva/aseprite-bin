FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt \
    && useradd --create-home --uid 10001 appuser

COPY --chown=appuser:appuser main.py .

USER appuser

EXPOSE 8000

# The gthread worker refreshes its heartbeat on every event-loop iteration, so
# the default 30s watchdog does not in fact kill a slow streaming request.
# --timeout 0 keeps that guarantee from silently depending on gunicorn
# internals across upgrades: a truncated download is a corrupt release file.
CMD ["sh", "-c", "exec gunicorn \
    --bind 0.0.0.0:${PORT:-8000} \
    --workers 2 \
    --threads 8 \
    --timeout 0 \
    --access-logfile - \
    --error-logfile - \
    main:app"]
