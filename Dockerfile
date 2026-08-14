FROM python:3.10-slim

ARG CLIENT_NAME

WORKDIR /app

# Install system dependencies and Microsoft ODBC driver required by pyodbc
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        apt-transport-https \
        lsb-release \
        unixodbc \
        unixodbc-dev \
        g++ \
    && curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/microsoft.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/debian/11/prod bullseye main" > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql17 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py ./
COPY webhook_consumer.py ./
COPY constants.py ./
COPY utils.py ./
COPY message_integration.py ./
COPY template_configs.py ./
COPY config_loader.py ./
COPY config.yaml ./
COPY ${CLIENT_NAME} ./${CLIENT_NAME}

ENV PYTHONUNBUFFERED=1
ENV PORT=80
EXPOSE 80

CMD ["python", "app.py"]
