# MCP único (zabbix-grafana-mcp): só a biblioteca padrão do Python, sem pip.
FROM python:3.13.18-alpine3.24

RUN adduser -D -H -u 10001 mcp
WORKDIR /app
COPY gateway.py /app/gateway.py

USER 10001:10001
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
EXPOSE 8765
HEALTHCHECK --interval=15s --timeout=5s --retries=5 \
  CMD ["python", "-c", "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:8765/healthz', timeout=4); sys.exit(0)"]
ENTRYPOINT ["python", "/app/gateway.py"]
