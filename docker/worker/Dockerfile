FROM python:3.12-slim

WORKDIR /app

# Install Google Chrome stable (always latest) from Google's official apt repo.
# Selenium Manager (built into selenium>=4.6) auto-downloads the matching
# ChromeDriver on first run — no manual version pinning required.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    xvfb \
  && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
     | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
  && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
     > /etc/apt/sources.list.d/google-chrome.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends google-chrome-stable \
  && rm -rf /var/lib/apt/lists/*

ENV CHROME_BIN=/usr/bin/google-chrome
ENV DISPLAY=:99

# Start Xvfb virtual display then run the worker
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker.py .

ENTRYPOINT ["/entrypoint.sh"]
