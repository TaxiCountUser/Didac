FROM node:22-alpine

WORKDIR /app

# Instalar dependencias primero (cache de capas)
COPY package*.json ./
RUN npm install --omit=dev

# Copiar el resto del código
COPY . .

ENV NODE_ENV=production
ENV BACKEND_PORT=3000
EXPOSE 3000

CMD ["node", "src/server.js"]
