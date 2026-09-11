"""Сохранение правок презентации в бакет проекта.

Презентацию отдаёт сам бакет (маршрут `/`), сервис нужен ровно для одного:
принять отредактированный HTML из браузера и положить его в бакет вместо
index.html. Ключи от бакета живут только здесь — в страницу их класть нельзя,
их достанет любой, кто откроет исходник.

Кто имеет право публиковать, решает маршрут `/save` на платформе
(`auth: allowlist` — список почт в Project CR), а не этот код: до сервиса
запрос доходит уже с пройденной авторизацией.
"""

import datetime as dt
import os

import boto3
from botocore.config import Config
from fastapi import FastAPI, HTTPException, Request

MAX_BYTES = 5 * 1024 * 1024
# Отпечаток презентации: защита от того, чтобы случайным запросом не положить
# в бакет произвольную страницу вместо неё.
MARKER = "Скрепка для Додо ИС"

app = FastAPI(title="hackathon-clip-deck save")


def _client():
    # Оба checksum-параметра обязательны для SberCloud OBS: без них первый же
    # put_object падает с XAmzContentSHA256Mismatch (botocore >= 1.36).
    return boto3.client(
        "s3",
        endpoint_url=os.environ["S3_ENDPOINT"],
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=os.environ["S3_REGION"],
        config=Config(
            s3={"addressing_style": "virtual", "payload_signing_enabled": False},
            request_checksum_calculation="when_required",
            response_checksum_validation="when_required",
        ),
    )


@app.get("/healthz")
def healthz():
    return {"ok": True}


def validate(body: bytes) -> str:
    """Проверки присланного тела. Вынесены отдельно, чтобы их можно было
    прогнать на стенде, не трогая боевой бакет."""
    if not body:
        raise HTTPException(400, "пустой запрос")
    if len(body) > MAX_BYTES:
        raise HTTPException(413, "презентация больше 5 МБ — так не бывает, отклонено")

    try:
        html = body.decode("utf-8")
    except UnicodeDecodeError:
        raise HTTPException(400, "ожидается UTF-8")

    if not html.lstrip().lower().startswith("<!doctype html"):
        raise HTTPException(400, "это не HTML-страница")
    if MARKER not in html:
        raise HTTPException(400, "это не презентация «Скрепка для Додо ИС»")
    return html


@app.post("/save")
async def save(request: Request):
    body = await request.body()
    validate(body)

    s3 = _client()
    bucket = os.environ["S3_BUCKET"]

    # Прошлая версия уезжает в versions/ — чтобы неудачную правку можно было
    # откатить, а не восстанавливать по памяти.
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S")
    backup = None
    try:
        current = s3.get_object(Bucket=bucket, Key="index.html")["Body"].read()
        backup = "versions/index-%s.html" % stamp
        s3.put_object(
            Bucket=bucket,
            Key=backup,
            Body=current,
            ContentType="text/html; charset=utf-8",
            CacheControl="no-cache",
        )
    except s3.exceptions.NoSuchKey:
        pass

    s3.put_object(
        Bucket=bucket,
        Key="index.html",
        Body=body,
        ContentType="text/html; charset=utf-8",
        CacheControl="no-cache",
    )
    return {"ok": True, "saved": len(body), "backup": backup}


@app.get("/versions")
def versions():
    """Список сохранённых версий — чтобы было видно, к чему можно откатиться."""
    s3 = _client()
    got = s3.list_objects_v2(Bucket=os.environ["S3_BUCKET"], Prefix="versions/")
    items = [
        {"key": o["Key"], "size": o["Size"], "modified": o["LastModified"].isoformat()}
        for o in got.get("Contents", [])
    ]
    items.sort(key=lambda i: i["key"], reverse=True)
    return {"versions": items}
