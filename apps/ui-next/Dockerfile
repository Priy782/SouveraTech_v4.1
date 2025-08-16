# Multi-stage optional (hier einfach gehalten)
FROM node:20-alpine

WORKDIR /app

# Nur die Manifeste zuerst -> effizienteres Caching
COPY package*.json ./

RUN npm ci

# Quellcode kopieren und builden
COPY . ./
RUN npm run build

ENV NODE_ENV=production
EXPOSE 3000
CMD ["npm", "start"]
