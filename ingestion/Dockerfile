# Container for the ingestion jobs (currently the Betfair snapshot, run on Cloud Run in London
# because Betfair blocks logins from GitHub's US-based runners).
FROM python:3.12-slim
 
ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
 
WORKDIR /app
 
COPY requirements.txt .
RUN pip install -r requirements.txt
 
COPY *.py ./
 
# Extra arguments from the Cloud Run job (e.g. --hours 48) are appended to this.
ENTRYPOINT ["python", "load_betfair.py"]