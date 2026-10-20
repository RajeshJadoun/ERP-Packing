FROM node:22-alpine AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --legacy-peer-deps

COPY . .

# These values are baked into the Vite bundle. Only the publishable/anon key
# belongs here; never pass a service-role key or database password as a build arg.
ARG VITE_SUPABASE_URL=https://setup-required.supabase.co
ARG VITE_SUPABASE_ANON_KEY=setup-required-anon-key
ARG VITE_API_BASE_URL=http://localhost:5000/api/v1
ENV VITE_SUPABASE_URL=${VITE_SUPABASE_URL} \
    VITE_SUPABASE_ANON_KEY=${VITE_SUPABASE_ANON_KEY} \
    VITE_API_BASE_URL=${VITE_API_BASE_URL}

RUN npm run build

FROM nginxinc/nginx-unprivileged:stable-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:8080/health || exit 1
