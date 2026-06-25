FROM node:22-alpine

WORKDIR /app

# Instalar dependencias primero (cache de capas)
COPY package*.json ./
RUN npm install --omit=dev

# Copiar el resto del código
COPY . .

ENV NODE_ENV=production
# No fijamos BACKEND_PORT: el servidor usa $PORT (Render/Railway/Fly) y, en
# local, el BACKEND_PORT que define docker-compose. Fijarlo aquí rompía el
# health check de Render (escuchaba en 3000 en vez de en su $PORT).
EXPOSE 3000

CMD ["node", "src/server.js"]
