FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements-runtime.txt ./requirements-runtime.txt
RUN python -m pip install --no-cache-dir --upgrade pip \
    && python -m pip install --no-cache-dir -r requirements-runtime.txt \
    && useradd --create-home --shell /usr/sbin/nologin appuser

COPY --chown=appuser:appuser app ./app
COPY --chown=appuser:appuser run.py ./run.py

USER appuser
EXPOSE 10000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import os, urllib.request; port=os.getenv('PORT') or os.getenv('APP_PORT','5000'); urllib.request.urlopen(f'http://127.0.0.1:{port}/api/v1/health', timeout=4).read()" || exit 1

CMD ["sh", "-c", "exec gunicorn --workers ${GUNICORN_WORKERS:-2} --threads ${GUNICORN_THREADS:-4} --bind 0.0.0.0:${PORT:-${APP_PORT:-5000}} --timeout 60 --access-logfile - --error-logfile - run:app"]
