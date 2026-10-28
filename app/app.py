"""Minimal "Hello, World!" web application for Tech Challenge 2.

Deployed by GitHub Actions (CI) and Argo CD (CD) on the gitops branch.
"""
import os
import socket

from flask import Flask, jsonify

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "dev")


@app.get("/")
def hello():
    return "Hello, World!"


@app.get("/healthz")
def healthz():
    """Liveness/readiness probe used by Kubernetes and the ALB target group."""
    return jsonify(status="ok"), 200


@app.get("/info")
def info():
    """Shows which pod served the request, handy for watching HPA/ALB spread load."""
    return jsonify(version=APP_VERSION, pod=socket.gethostname())


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
