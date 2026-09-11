# ---- сборка: зависимости в изолированный venv ----
FROM python:3.12-slim AS build
ENV PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
# зависимости отдельным слоем — правка кода не пересобирает их
COPY requirements.txt .
RUN pip install --upgrade pip && pip install -r requirements.txt
COPY . .

# ---- рантайм: без инструментов сборки, не под root ----
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PATH="/opt/venv/bin:$PATH"
WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY --from=build /app /app
EXPOSE 8080
USER 65534:65534
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
