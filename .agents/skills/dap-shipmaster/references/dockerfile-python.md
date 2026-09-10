# Dockerfile rules — Python (MVP stack)

`dap-shipmaster` (Phase B) **rewrites** the template `Dockerfile` (which ships as a Go example) into
a Python image. Python is the only MVP stack; Node/Go come later.

## Hard requirements (must hold)

- **Multi-stage**: a build stage installs deps into a venv; the final stage copies only the venv + app. Keeps the runtime image small and dep-tool-free.
- **Non-root**: final `USER` is a numeric UID **≥ 1024** (use `65534`, matching the template and the manifest `runAsUser`). Pod Security `restricted` rejects root.
- **Pinned base image**: pin `python:3.12-slim` (or the project's version) — never `latest`.
- **Cache-friendly layering**: copy dependency manifests and install **before** copying source, so code edits don't bust the dependency layer.
- **No build toolchain in the final image**: no `gcc`/`build-essential` in the runtime stage; install wheels in build stage.
- **App listens on a port ≥ 1024** (e.g. 8080) — must match `containerPort` and the Service.

## Reference: pip + venv (FastAPI/uvicorn)

```dockerfile
# ---- build stage: install deps into an isolated venv ----
FROM python:3.12-slim AS build
ENV PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
# deps first — this layer is cached until requirements change
COPY requirements.txt .
RUN pip install --upgrade pip && pip install -r requirements.txt
# then the app
COPY . .

# ---- runtime stage: minimal, non-root ----
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PATH="/opt/venv/bin:$PATH"
WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY --from=build /app /app
EXPOSE 8080
USER 65534:65534
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

Adapt to the real project: entrypoint module (`main:app`), port, and dependency manifest
(`requirements.txt`, or `pyproject.toml` + a lock). If the project uses **uv**, mirror the
pattern: `uv sync --frozen` into a venv in the build stage, copy the venv into runtime, stay
non-root. Don't introduce a dependency tool the project doesn't already use.

## Health endpoint

The manifest probes `livenessProbe`/`readinessProbe` on an HTTP path (template default
`/healthz` on 8080). Ensure the app actually serves it (a tiny `GET /healthz → 200` is enough),
or change the probe path in `k8s/deployment.yaml` to a real one.

## Anti-patterns (will break the build or the pod)

- `FROM python:latest` / unpinned base → non-reproducible.
- Running as root (no `USER`, or `USER 0`) → pod rejected by `restricted` PSS.
- Single-stage with `pip install` + source in one layer → fat image, poor caching.
- Copying source before deps → every code change reinstalls all dependencies.
- Hardcoding secrets / `DATABASE_URL` in the image → secrets come from K8s Secrets at runtime (see manifest-rules.md), never baked in.
