FROM node:20-slim

# Install ffmpeg and build tools for native modules (sharp)
RUN apt-get update && apt-get install -y ffmpeg && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy package.json first so Docker caches the npm install layer.
# This layer only rebuilds when package.json changes — not on every code push.
COPY package.json package-lock.json* ./
RUN npm install

# Copy source after dependencies — code changes don't trigger npm reinstall
COPY src/ ./src/

CMD ["node", "src/index.mjs"]
