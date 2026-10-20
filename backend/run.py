"""Development entrypoint. Production should use a WSGI server such as Gunicorn."""

from app import create_app
from app.config import Settings

settings = Settings()
app = create_app()

if __name__ == "__main__":
    app.run(host=settings.app_host, port=settings.app_port, debug=settings.app_env == "development")
