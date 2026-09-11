"""Заливка презентации в бакет проекта.

Шлёт только изменившиеся файлы: видео весит 35 МБ, и отправлять их заново
на каждую правку текста — долго и незачем. Что уже лежит в бакете, скрипт
узнаёт из манифеста с контрольными суммами, который сам же там и хранит.
"""

import hashlib
import json
import mimetypes
import os

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config

MANIFEST_KEY = '.upload-manifest.json'

# Видео уезжает многочастевой отправкой, и на медленном канале хранилище
# успевало закрыть соединение раньше, чем часть долетала (RequestTimeout).
# Части меньше, ожидание дольше, повторов больше.
TRANSFER = TransferConfig(
    multipart_threshold=8 * 1024 * 1024,
    multipart_chunksize=4 * 1024 * 1024,
    max_concurrency=2,
)

s3 = boto3.client('s3', endpoint_url=os.environ['S3_ENDPOINT'],
    aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],
    aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'],
    region_name=os.environ['S3_REGION'],
    config=Config(
        s3={'addressing_style': 'virtual', 'payload_signing_enabled': False},
        # Оба параметра обязательны для SberCloud OBS: без них первый put_object
        # падает с XAmzContentSHA256Mismatch (botocore >= 1.36).
        request_checksum_calculation='when_required',
        response_checksum_validation='when_required',
        connect_timeout=30, read_timeout=300,
        retries={'max_attempts': 10, 'mode': 'standard'},
    ))
bucket = os.environ['S3_BUCKET']
src = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'site')


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


try:
    known = json.loads(s3.get_object(Bucket=bucket, Key=MANIFEST_KEY)['Body'].read())
except Exception:
    known = {}

current, sent, skipped = {}, 0, 0
for root, _, files in os.walk(src):
    for f in files:
        path = os.path.join(root, f)
        key = os.path.relpath(path, src)
        current[key] = digest(path)
        if known.get(key) == current[key]:
            skipped += 1
            continue

        ctype = mimetypes.guess_type(path)[0] or 'application/octet-stream'
        if ctype == 'text/html':
            ctype = 'text/html; charset=utf-8'
        # no-cache для всего: файлы заменяются под одними и теми же именами,
        # а долгий кэш показывал бы докладчику прошлую версию. Браузер всё
        # равно кэширует, но переспрашивает — неизменившийся файл придёт как 304.
        s3.upload_file(path, bucket, key, Config=TRANSFER,
                       ExtraArgs={'ContentType': ctype, 'CacheControl': 'no-cache'})
        sent += 1
        print('залито %s (%d байт, %s)' % (key, os.path.getsize(path), ctype))

s3.put_object(Bucket=bucket, Key=MANIFEST_KEY,
              Body=json.dumps(current, indent=2).encode(),
              ContentType='application/json', CacheControl='no-cache')

print('отправлено файлов: %d, пропущено без изменений: %d' % (sent, skipped))
print('в бакете:', sorted(o['Key'] for o in s3.list_objects_v2(Bucket=bucket).get('Contents', [])))
