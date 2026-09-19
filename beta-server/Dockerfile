FROM node:24-bookworm-slim

WORKDIR /app

COPY --chown=node:node package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY --chown=node:node src ./src
RUN chmod 0755 /app /app/src \
  && chmod 0644 /app/package.json /app/src/*.mjs \
  && mkdir -p /var/lib/vaani \
  && chown node:node /var/lib/vaani \
  && chmod 0755 /var/lib/vaani

USER node

EXPOSE 8080

CMD ["node", "src/server.mjs"]
