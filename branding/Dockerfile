ARG BASE_IMAGE=ghcr.io/open-webui/open-webui:v0.13.3
FROM ${BASE_IMAGE}

WORKDIR /app/backend
COPY branding/dewa_app.py branding/start-dewa.sh ./
# Open WebUI copies build/static into its runtime static directory at startup.
COPY branding/assets/ /app/build/static/
COPY branding/assets/favicon.png /app/build/favicon.png
COPY branding/licenses/ /usr/share/licenses/dewa/open-webui/

ENV DEWA_APP_NAME=DEWA
CMD ["bash", "/app/backend/start-dewa.sh"]
