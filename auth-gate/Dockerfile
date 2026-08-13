FROM python:3.12-alpine

WORKDIR /app

ENV PYTHONUNBUFFERED=1

COPY server.py /app/server.py

EXPOSE 3000

CMD ["python", "/app/server.py"]