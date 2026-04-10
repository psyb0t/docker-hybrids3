FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends libmagic1 \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 hybrids3 \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash hybrids3

WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

RUN mkdir -p /data /config \
    && chown -R hybrids3:hybrids3 /data /config /app

USER hybrids3

EXPOSE 8080

CMD ["python", "main.py"]
