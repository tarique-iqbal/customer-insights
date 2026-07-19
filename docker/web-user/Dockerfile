FROM node:20-alpine

WORKDIR /app

COPY web-user/package*.json ./

RUN npm install

COPY web-user/ .

EXPOSE 3000

CMD ["npm", "start"]
