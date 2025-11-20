# docker/normalizer/Dockerfile
FROM python:3.14-slim

# Install minimal deps (file for mime detection)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install mutagen for MP4 tag handling
RUN pip install --no-cache-dir mutagen

WORKDIR /app

# Copy normalization script and entrypoin into image
COPY normalize_dirs.py /app/normalize_dirs.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /app/normalize_dirs.py

ENTRYPOINT ["/entrypoint.sh"]
