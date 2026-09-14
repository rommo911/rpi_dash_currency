"""The one Flask app instance. Separate from app.py so routes/*.py importing
it don't trigger a second `__main__` re-run with a dead second instance."""
import os

from flask import Flask

import logging_setup  # noqa: F401 - configures logging as a side effect
from config import FLAGS_DIR

app = Flask(__name__)
os.makedirs(FLAGS_DIR, exist_ok=True)
