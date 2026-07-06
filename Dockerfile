FROM public.ecr.aws/lambda/python:3.10


COPY app.py ${LAMBDA_TASK_ROOT}
COPY ./requirements.txt ${LAMBDA_TASK_ROOT}
COPY ./webhook_consumer.py ${LAMBDA_TASK_ROOT}
COPY ./constants.py ${LAMBDA_TASK_ROOT}
COPY ./utils.py ${LAMBDA_TASK_ROOT}
COPY ./message_integration.py ${LAMBDA_TASK_ROOT}
COPY ./template_configs.py ${LAMBDA_TASK_ROOT}

# Install the Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

CMD ["app.lambda_handler"]