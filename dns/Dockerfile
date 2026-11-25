FROM python:3.13-alpine

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY --chown=65532:65532 upsert.py /app/upsert.py
USER 65532:65532

ENTRYPOINT ["python", "/app/upsert.py"]
