FROM node:22-alpine
WORKDIR /app
COPY package.json ./
COPY src ./src
ENV NODE_ENV=production PORT=8080 DATABASE_PATH=/data/autometa.db
# The DB lives on a mounted volume at /data (docker run -v ... or a Railway
# volume). No VOLUME instruction: Railway rejects it in Dockerfiles.
RUN mkdir -p /data && chown node:node /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -qO- "http://127.0.0.1:${PORT:-8080}/health" || exit 1
USER node
CMD ["node", "--disable-warning=ExperimentalWarning", "src/index.js"]
