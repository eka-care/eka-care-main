FROM python:3.10-slim

ARG CLIENT_NAME

WORKDIR /app

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

ENV PORT=80
EXPOSE 80

CMD ["python", "app.py"]
