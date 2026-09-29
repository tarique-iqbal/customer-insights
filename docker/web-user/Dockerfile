FROM node:20-alpine AS base

WORKDIR /app

COPY web-user/package*.json ./

RUN npm install

COPY web-user/ .

# prod: static vite build served by nginx. No dev server, no source watching.
# Built with --target prod (CI only) — see docker/web-user/generate-env.sh
# for how VITE_API_URL reaches the browser despite being baked at build time.
FROM base AS build

RUN npm run build

FROM nginx:1.25.5-alpine AS prod

COPY --from=build /app/dist /usr/share/nginx/html
COPY docker/web-user/nginx.conf /etc/nginx/conf.d/default.conf
COPY docker/web-user/generate-env.sh /docker-entrypoint.d/40-generate-env.sh

RUN chmod +x /docker-entrypoint.d/40-generate-env.sh

EXPOSE 80

# dev: the vite dev server. Last stage, so a plain untargeted build defaults
# here — matches every existing build command in this repo.
FROM base AS dev

EXPOSE 5173

CMD ["npm", "start"]
