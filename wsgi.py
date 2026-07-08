"""
Entry point for gunicorn:

    gunicorn --workers 2 --bind 127.0.0.1:8000 wsgi:app
"""

from app import app

if __name__ == "__main__":
    app.run()
