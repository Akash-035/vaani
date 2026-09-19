FROM node:24-bookworm-slim
WORKDIR /app
COPY package.json ./
COPY src ./src
USER node
EXPOSE 8080
CMD ["node", "src/server.mjs"]
