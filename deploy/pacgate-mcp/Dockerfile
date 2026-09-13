FROM python:3.12-slim

WORKDIR /app

# Copy requirements first for layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

EXPOSE 8000

# Use a heredoc-safe CMD: the module runs its own streams via mcp.run()
CMD ["python", "server.py"]
