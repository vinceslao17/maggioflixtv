FROM python:3.12-alpine
LABEL org.opencontainers.image.source="https://github.com/vinceslao17/maggioflixtv" \
      org.opencontainers.image.description="MaggioFlix Live: avanzamento dei download in tempo reale per l'app MaggioFlix" \
      org.opencontainers.image.licenses="GPL-3.0"
WORKDIR /app
COPY app.py /app/app.py
ENV PYTHONUNBUFFERED=1 PORT=8790
EXPOSE 8790
USER 1000:1000
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8790/health >/dev/null || exit 1
CMD ["python", "/app/app.py"]
