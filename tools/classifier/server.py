from __future__ import annotations

import argparse
import sys
import threading
import uvicorn
from fastapi import FastAPI, HTTPException

from .catalog import CATALOG, download_model, load_classifier
from .defaults import DEFAULT_BIND_HOST, DEFAULT_BIND_PORT, DEFAULT_MODEL
from .models.base import BaseClassifier, ClassifyRequest, ClassifyResponse


class ModelHost:
    """Holds the active classifier while loading asynchronously."""

    def __init__(self) -> None:
        self.classifier: BaseClassifier | None = None
        self.loading_error: str | None = None

    def load(self, model_name: str, local_path: str | None) -> None:
        try:
            self.classifier = load_classifier(model_name, local_path)
            self.loading_error = None
        except Exception as e:
            self.loading_error = str(e)
            print(f"[!] Error loading model '{model_name}': {e}", file=sys.stderr)


def build_app(host: ModelHost, model_name: str) -> FastAPI:
    app = FastAPI(
        title="Nova Safety Classifier",
        description="External command safety classification REST endpoint for Nova Agent.",
        version="0.1.0",
    )

    @app.get("/health")
    def health() -> dict[str, str]:
        if host.loading_error:
            return {"status": "error", "detail": host.loading_error}
        return {
            "status": "ok",
            "model": model_name,
            "classifier": "ready" if host.classifier is not None else "loading",
        }

    @app.post("/classify", response_model=ClassifyResponse)
    def classify(request: ClassifyRequest) -> ClassifyResponse:
        if host.classifier is None:
            if host.loading_error:
                raise HTTPException(status_code=500, detail=f"Model failed to load: {host.loading_error}")
            raise HTTPException(status_code=503, detail="Classifier is still loading, please retry in a moment")
        return host.classifier.classify(request.command, request.cwd)

    return app


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Nova Standalone Safety Classifier Service")
    subparsers = parser.add_subparsers(dest="command", help="Subcommand to execute")

    # Serve subcommand (default)
    serve_parser = subparsers.add_parser("serve", help="Start the classifier HTTP server")
    serve_parser.add_argument(
        "--model",
        choices=list(CATALOG.keys()),
        default=DEFAULT_MODEL,
        help=f"Model preset to serve (default: {DEFAULT_MODEL})",
    )
    serve_parser.add_argument(
        "--path",
        type=str,
        default=None,
        help="Custom path to an ONNX model directory or .onnx file",
    )
    serve_parser.add_argument("--host", default=DEFAULT_BIND_HOST, help=f"Bind host (default: {DEFAULT_BIND_HOST})")
    serve_parser.add_argument("--port", type=int, default=DEFAULT_BIND_PORT, help=f"Bind port (default: {DEFAULT_BIND_PORT})")
    serve_parser.add_argument("--reload", action="store_true", help="Enable auto-reload for development")

    # Download subcommand
    download_parser = subparsers.add_parser("download", help="Pre-download model weights from HuggingFace")
    download_parser.add_argument(
        "--model",
        choices=[k for k, v in CATALOG.items() if v.repo_id],
        default=DEFAULT_MODEL,
        help="Model preset to download",
    )

    # List models subcommand
    subparsers.add_parser("list", help="List available model presets")

    # Default to serve if no subcommand provided
    if len(sys.argv) == 1 or sys.argv[1] not in ["serve", "download", "list", "-h", "--help"]:
        sys.argv.insert(1, "serve")

    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if args.command == "list":
        print("\nAvailable Classifier Model Presets:")
        for key, spec in CATALOG.items():
            print(f"  • {key:12} : {spec.description}")
        print()
        return

    if args.command == "download":
        download_model(args.model)
        return

    # Serve command
    host = ModelHost()
    threading.Thread(
        target=host.load,
        args=(args.model, args.path),
        daemon=True,
    ).start()

    print(f"[*] Starting Nova Safety Classifier ({args.model}) on http://{args.host}:{args.port}...")
    print(f"[*] Nova Endpoint: http://{args.host}:{args.port}/classify")
    print(f"[*] Set in your environment: export NOVA_BASH_CLASSIFIER_URL=http://{args.host}:{args.port}/classify\n")

    uvicorn.run(
        build_app(host, args.model),
        host=args.host,
        port=args.port,
        log_level="warning",
        access_log=False,
    )


if __name__ == "__main__":
    main()
