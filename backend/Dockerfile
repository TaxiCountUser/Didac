FROM node:22-alpine

WORKDIR /app

# Instalar dependencias primero (cache de capas). npm ci = build reproducible
# desde package-lock.json (ya sincronizado con package.json).
COPY package*.json ./
RUN npm ci --omit=dev

# Copiar el resto del código
COPY . .

ENV NODE_ENV=production
# No fijamos BACKEND_PORT: el servidor usa $PORT (Render/Railway/Fly) y, en
# local, el BACKEND_PORT que define docker-compose. Fijarlo aquí rompía el
# health check de Render (escuchaba en 3000 en vez de en su $PORT).
EXPOSE 3000

# Ejecutar como usuario sin privilegios (la imagen node:* trae el usuario 'node').
USER node

CMD ["node", "src/server.js"]
