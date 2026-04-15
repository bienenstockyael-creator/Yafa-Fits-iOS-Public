FROM node:20-slim

# Install ffmpeg for frame extraction
RUN apt-get update && apt-get install -y ffmpeg && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json .
RUN npm install

COPY src/ ./src/

CMD ["node", "src/index.mjs"]
