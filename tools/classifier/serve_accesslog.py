"""Erisim-log'lu classifier launcher (access_log=True).

Repo'daki server.py'yi DEGISTIRMEZ; sadece build_app + ModelHost'u
import edip uvicorn'u access_log=True ile calistirir. Amac: Nova'nin
her POST /classify cagrisini log'a dusurerek classifier'in kullanildigini
zararsiz sekilde dogrulamak.
"""
from __future__ import annotations
import argparse
import sys
import threading

import uvicorn
from .defaults import DEFAULT_BIND_HOST, DEFAULT_BIND_PORT, DEFAULT_MODEL
from .server import ModelHost, build_app


def main() -> None:
    parser = argparse.ArgumentParser(description="Nova Safety Classifier (access_log ON)")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--path", default=None)
    parser.add_argument("--host", default=DEFAULT_BIND_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_BIND_PORT)
    args = parser.parse_args()

    host = ModelHost()
    threading.Thread(target=host.load, args=(args.model, args.path), daemon=True).start()
    app = build_app(host, args.model)

    print(f"[*] Access-log'lu classifier basladi: http://{args.host}:{args.port}/classify", file=sys.stderr)
    sys.stdout.flush()
    uvicorn.run(app, host=args.host, port=args.port, log_level="info", access_log=True)


if __name__ == "__main__":
    main()
