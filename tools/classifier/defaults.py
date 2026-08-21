"""Single source for the classifier service's CLI defaults.

The Zig side is fully env-driven (`NOVA_BASH_CLASSIFIER_URL`, no default URL),
so these defaults exist only on the Python side and must stay in sync between
the serve entrypoints (server.py, serve_accesslog.py).
"""

DEFAULT_BIND_HOST = "127.0.0.1"
DEFAULT_BIND_PORT = 8765
DEFAULT_MODEL = "modernbert"
