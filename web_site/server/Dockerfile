FROM node:20-alpine
WORKDIR /srv
COPY server/server.js ./server/server.js
COPY index.html eula.html og-default.png ./
ENV PORT=8080 STATIC_DIR=/srv
EXPOSE 8080
USER node
CMD ["node", "server/server.js"]
