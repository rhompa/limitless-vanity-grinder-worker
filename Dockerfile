FROM ghcr.io/wincerchan/solvanitycl:latest

# Install pip + FastAPI dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3-pip && \
    pip3 install --no-cache-dir --break-system-packages --ignore-installed \
        fastapi==0.115.* \
        uvicorn[standard]==0.34.* \
        cryptography==44.* \
        pydantic==2.* && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy worker code
WORKDIR /worker
COPY server.py grind_handler.py encryption.py entrypoint.sh ./
RUN chmod +x entrypoint.sh

EXPOSE 8080

CMD ["./entrypoint.sh"]
