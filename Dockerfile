FROM python:3.11-slim AS builder

ARG HERMES_GIT_REF=main

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone --depth 1 --branch "${HERMES_GIT_REF}" --recurse-submodules https://github.com/NousResearch/hermes-agent.git

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

RUN pip install --no-cache-dir --upgrade pip setuptools wheel
RUN pip install --no-cache-dir -e "/opt/hermes-agent[messaging,cron,cli,pty]"

# Pre-install playwright into the venv so the browser tool works out-of-the-box.
RUN pip install --no-cache-dir playwright


FROM python:3.11-slim

# System dependencies split into two groups:
#  1) Always-needed runtime bits (tini, CA certs, curl for healthchecks, git for skills, gh for the GitHub CLI).
#  2) Playwright/Chromium shared libraries so the browser tool works without a post-install step.
#
# gh is pulled from the official Debian apt repo (keeps the image small vs. the GitHub apt repo setup).
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gh \
    tini \
    # Playwright/Chromium runtime libraries (mirrors `playwright install-deps chromium`)
    libglib2.0-0 \
    libnss3 \
    libnspr4 \
    libdbus-1-3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libatspi2.0-0 \
    libexpat1 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxrandr2 \
    libxkbcommon0 \
    libgbm1 \
    libcairo2 \
    libpango-1.0-0 \
    libasound2 \
    libcups2 \
    libx11-6 \
    libxcb1 \
    fonts-liberation \
    fonts-noto-color-emoji \
  && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/venv/bin:${PATH}" \
  PYTHONUNBUFFERED=1 \
  # Make `hermes_constants` and other hermes-agent internals importable from
  # skill scripts (e.g. google-workspace/setup.py) without needing PYTHONPATH gymnastics.
  PYTHONPATH="/opt/hermes-agent" \
  HERMES_HOME=/data/.hermes \
  HOME=/data \
  # Install Playwright browsers to a location under /opt so they survive inside
  # the image but aren't written to the user volume at runtime.
  PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /opt/hermes-agent /opt/hermes-agent

# Pre-download Chromium (headless shell + ffmpeg). Needs the venv's playwright CLI.
RUN playwright install chromium \
  && chmod -R a+rX /opt/playwright-browsers

WORKDIR /app
COPY scripts/entrypoint.sh /app/scripts/entrypoint.sh
COPY scripts/bootstrap-extras.sh /app/scripts/bootstrap-extras.sh
RUN chmod +x /app/scripts/entrypoint.sh /app/scripts/bootstrap-extras.sh

ENTRYPOINT ["tini", "--"]
CMD ["/app/scripts/entrypoint.sh"]
