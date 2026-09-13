"""The one Flask app instance, shared by every route module.

Deliberately its own tiny file, not part of app.py: `python app.py` runs
that file as `__main__`, not as a module named `app`. If a routes/*.py
module did `from app import app`, Python would import a SECOND, separate
copy of app.py under the name "app" — a different Flask instance than the
one actually serving requests, so every route registered on it would be
silently dead. Importing from this never-run-directly module avoids that.
"""
import os

from flask import Flask

import logging_setup  # noqa: F401 - configures logging as a side effect
from config import FLAGS_DIR

app = Flask(__name__)
os.makedirs(FLAGS_DIR, exist_ok=True)
