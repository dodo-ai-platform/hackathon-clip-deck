import boto3, mimetypes, os
from botocore.config import Config

s3 = boto3.client('s3', endpoint_url=os.environ['S3_ENDPOINT'],
    aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],
    aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'],
    region_name=os.environ['S3_REGION'],
    config=Config(
        s3={'addressing_style': 'virtual', 'payload_signing_enabled': False},
        request_checksum_calculation='when_required',
        response_checksum_validation='when_required',
    ))
bucket = os.environ['S3_BUCKET']
src = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'site')
for root, _, files in os.walk(src):
    for f in files:
        path = os.path.join(root, f)
        key = os.path.relpath(path, src)
        ctype = mimetypes.guess_type(path)[0] or 'application/octet-stream'
        if ctype == 'text/html':
            ctype = 'text/html; charset=utf-8'
        # no-cache для всего: файлы заменяются под теми же именами (index.html,
        # media/chat.mp4), а иммутабельный кэш показывал бы докладчику старую
        # версию. Браузер всё равно кэширует, но каждый раз переспрашивает —
        # неизменившийся файл приходит как 304, без повторной загрузки.
        cache = 'no-cache'
        s3.upload_file(path, bucket, key, ExtraArgs={'ContentType': ctype, 'CacheControl': cache})
        print('uploaded', key, os.path.getsize(path), 'bytes', ctype)
print('bucket objects:', [o['Key'] for o in s3.list_objects_v2(Bucket=bucket).get('Contents', [])])
