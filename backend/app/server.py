"""Entry point for uvicorn: `uvicorn app.server:app --host 0.0.0.0 --port 8090`."""
from .config import load_settings
from .main import create_app

settings, created = load_settings()
if created:
    print("\nFirst run: access tokens were created in", settings.data_dir / "tokens.json")
    print("  upload token (PC uploader):", settings.upload_token)
    print("  read token   (phone app)  :", settings.read_token, "\n")
app = create_app(settings)
