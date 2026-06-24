# Telemetría y Desarrollo Agéntico Extremo — Portal Corporativo

Este proyecto implementa la arquitectura solicitada para el monitoreo de flotas masivas, integrando un pipeline de alta concurrencia con NestJS, Kafka, TimescaleDB, Prisma, y un agente de IA reactivo.

El repositorio raíz actúa como **monorepo orquestador**: la infraestructura compartida (Docker, Terraform, pruebas de carga) vive aquí, mientras que `backend`, `frontend` y `mobile` son **submódulos de Git** con repositorios independientes.

## 📦 Clonado e Inicialización (Submódulos)

Los directorios `backend/`, `frontend/` y `mobile/` no contienen el código fuente hasta inicializar los submódulos. Clona el proyecto completo con:

```bash
git clone --recurse-submodules https://github.com/simonMovilidad/project.git
cd project
```

Si ya clonaste sin submódulos:

```bash
git submodule update --init --recursive
```

Para actualizar los submódulos a la versión registrada en el commit actual del monorepo:

```bash
git submodule update --recursive
```

Para traer los últimos cambios de cada repositorio hijo:

```bash
git submodule update --remote --merge
```

| Submódulo | Repositorio |
|-----------|-------------|
| `backend/` | [simonMovilidad/backend](https://github.com/simonMovilidad/backend) |
| `frontend/` | [simonMovilidad/frontend](https://github.com/simonMovilidad/frontend) |
| `mobile/` | [simonMovilidad/mobile](https://github.com/simonMovilidad/mobile) |

> **Nota:** Cada submódulo apunta a un commit específico. Si un directorio aparece vacío o incompleto, ejecuta `git submodule update --init --recursive` antes de instalar dependencias.

---

## 🔐 Variables de Entorno

Cada submódulo usa su propio archivo `.env` en su directorio. Puedes copiar los ejemplos y ajustar según tu entorno (local, Docker o dispositivo físico).

### Backend (`backend/.env`)

| Variable | Requerida | Descripción | Valor por defecto / ejemplo |
|----------|-----------|-------------|----------------------------|
| `DATABASE_URL` | **Sí** | Conexión PostgreSQL/TimescaleDB para Prisma | `postgresql://postgres:password@localhost:5433/telemetry_db` |
| `KAFKA_BROKER` | No | Host:puerto del broker Kafka | `localhost:9092` |
| `PORT` | No | Puerto HTTP del API NestJS | `3002` |
| `OPENAI_API_KEY` | No | API key de OpenAI para el fallback del agente IA (`/ai/chat`). Sin ella, el intent parser local sigue funcionando | — |

Ejemplo `backend/.env`:

```env
DATABASE_URL=postgresql://postgres:password@localhost:5433/telemetry_db
KAFKA_BROKER=localhost:9092
PORT=3002
OPENAI_API_KEY=sk-...
```

> **Nota:** Con `docker compose up -d` (solo infra), la base expone el puerto **5433** en el host (`5433:5432`). Si el backend corre dentro de Docker Compose, usa `db:5432` como en el `docker-compose.yml`.

---

### Frontend (`frontend/.env`)

| Variable | Requerida | Descripción | Valor por defecto / ejemplo |
|----------|-----------|-------------|----------------------------|
| `NEXT_PUBLIC_API_URL` | No | URL base del backend (REST: vehículos, alertas, chat IA) | `http://localhost:3002` |
| `NEXT_PUBLIC_WS_URL` | No | URL del servidor WebSocket (namespace `/events`) | `http://localhost:3002` |

Ejemplo `frontend/.env`:

```env
NEXT_PUBLIC_API_URL=http://localhost:3002
NEXT_PUBLIC_WS_URL=http://localhost:3002
```

> Las variables `NEXT_PUBLIC_*` se embeben en el bundle del cliente. En producción apunta a la URL pública del backend.

---

### Mobile (`mobile/.env`)

| Variable | Requerida | Descripción | Valor por defecto / ejemplo |
|----------|-----------|-------------|----------------------------|
| `EXPO_PUBLIC_BACKEND_URL` | No | URL base del backend para enviar telemetría (`POST /telemetry/ingest`) | `http://localhost:3002` |

Ejemplo `mobile/.env`:

```env
# Emulador / misma máquina
EXPO_PUBLIC_BACKEND_URL=http://localhost:3002

# Dispositivo físico (usa la IP de tu PC en la red local)
# EXPO_PUBLIC_BACKEND_URL=http://192.168.1.X:3002
```

> En dispositivo físico **no uses** `localhost`; debe ser la IP de la máquina donde corre el backend.

---

### Raíz (opcional — pruebas de carga k6)

| Variable | Requerida | Descripción | Valor por defecto |
|----------|-----------|-------------|-------------------|
| `BASE_URL` | No | Endpoint de ingesta para `load-test.js` | `http://localhost:3002/telemetry/ingest` |

```bash
BASE_URL=http://localhost:3002/telemetry/ingest k6 run load-test.js
```

---

## 🚀 Arquitectura y Decisiones (DDD & Clean Architecture)

1. **Ingesta Orientada a Eventos:**
   - La API (`/telemetry/ingest`) recibe los datos móviles y los inyecta en **Kafka** (Broker). Esto garantiza que el endpoint responda con un `202 Accepted` en ~5ms, absorbiendo picos masivos de concurrencia.
   - Un **Consumer** asíncrono lee los eventos y los persiste en la base de datos de manera controlada.
2. **Persistencia de Series de Tiempo (TimescaleDB):**
   - Las coordenadas GPS se guardan en una **Hipertabla** de TimescaleDB. Al particionar los datos por la columna `timestamp` incluida en la PK (`@@id([id, timestamp])`), aseguramos lecturas en milisegundos y evitamos que los B-Trees de índices estándar colapsen a largo plazo.
3. **Resiliencia y Circuit Breakers:**
   - Se implementó la librería `opossum` para proteger la base de datos. Si TimescaleDB presenta problemas bajo carga extrema, el *Circuit Breaker* se "abre", reteniendo las peticiones y evitando que todo el servicio backend caiga en efecto dominó.
4. **Dashboard y WebSockets:**
   - Una vez la telemetría se guarda exitosamente, el backend emite un evento `telemetry.update` a través de `@nestjs/websockets` (Socket.io) para renderizado en vivo en la SPA.
5. **Agente de IA Híbrido:**
   - Un motor de *Intent Parsing* intercepta peticiones locales acotadas y consulta Prisma de forma nativa (0ms latencia). Solo si la pregunta escapa del flujo, se le envía el contexto a OpenAI. Entiende: vehículos detenidos, exceso de velocidad, combustible, alertas críticas y resúmenes.

---

## 🛠️ Instrucciones de Ejecución

> Asegúrate de haber [inicializado los submódulos](#-clonado-e-inicialización-submódulos) antes de continuar.

### 1. Entorno y Docker
Asegúrate de tener Docker instalado. Ejecuta el entorno base (PostgreSQL + TimescaleDB, Apache Kafka con KRaft, Redis):
```bash
docker compose up -d
```

### 2. Backend (NestJS)

Crea `backend/.env` con al menos `DATABASE_URL` (ver [variables de entorno](#-variables-de-entorno)).

```bash
cd backend
npm install
npx prisma generate
npx prisma db push
npm run start:dev
```
El servidor backend escuchará en el puerto **3002**.

**(Opcional — Hipertabla TimescaleDB en Producción):**
```bash
npx ts-node setup_timescale.ts
```

### 3. Portal Web (Next.js)

Crea `frontend/.env` con `NEXT_PUBLIC_API_URL` y `NEXT_PUBLIC_WS_URL` (ver [variables de entorno](#-variables-de-entorno)).

```bash
cd frontend
npm install
npm run dev
```
El portal estará disponible en `http://localhost:3000`.

### 4. App Móvil (React Native / Expo)

Crea `mobile/.env` con `EXPO_PUBLIC_BACKEND_URL` (ver [variables de entorno](#-variables-de-entorno)).

```bash
cd mobile
npm install
npm run start
```

### 5. Pruebas de Caos (k6)
Para simular carga de 100 vehículos con inyección de errores (5%) y duplicados (10%):
```bash
k6 run load-test.js
```

### 6. IaC (Infraestructura como Código)
En la raíz encontrarás el archivo `main.tf`, un esquema de Terraform preparado para desplegar en AWS MSK (Kafka administrado), RDS para TimescaleDB, y un cluster ECS Fargate con su `aws_ecs_service` de alta disponibilidad (2 réplicas) para NestJS.

### 7. Orquestación Full-Stack Local (Docker Compose completo)
El `docker-compose.yml` orquesta **todos** los servicios en conjunto: TimescaleDB, Kafka, Redis, el backend NestJS, y el portal Next.js:
```bash
docker compose up --build
```

---

## 🤖 Auditoría de IA (Fundamental)

Como parte de la metodología de trabajo con herramientas agénticas, aquí se documenta la auditoría arquitectónica donde se rechazaron sugerencias deficientes del IDE:

### 1. Rechazo al enfoque de LangChain directo para Telemetría Básica
- **Sugerencia de IA:** Al solicitar el agente operativo, la IA sugirió instanciar la clase entera de `LangChain` con *Function Calling* de OpenAI para que la LLM construyera dinámicamente las queries SQL (text-to-SQL).
- **El Problema:** Riesgo de inyección de código si no está finamente curado, introduce ~3-5 segundos de latencia y un consumo exagerado de tokens para preguntas deterministas.
- **Mi refactorización:** Guié a la IA para crear un `AiService` híbrido con un motor de *Intent Parsing*. Intercepta peticiones locales acotadas y consulta Prisma de forma nativa (0ms latencia). Solo si la pregunta escapa del flujo se envía contexto a OpenAI. Esto garantiza velocidad, ahorro de tokens y resiliencia determinista.

### 2. Configuración de Prisma v7 vs TimescaleDB
- **Sugerencia de IA:** La IA inicializó el proyecto con `npx prisma init` instalando Prisma `7.8.0` y sugirió un modelo tradicional `model TelemetryEvent { id String @id @default(uuid()) ... }`.
- **El Problema:** Prisma v7 tiene bugs con `prisma studio`. Además, el modelo sugerido es **incompatible con TimescaleDB**, que requiere partición estricta por tiempo. El script para crear la hipertabla fallaría con `cannot create a unique index without the column "timestamp"`.
- **Mi refactorización:** Forcé un downgrade a Prisma `6.19.3` donde el tooling es 100% estable. Luego refactoricé el esquema para incluir llaves compuestas `@@id([id, timestamp])`, permitiendo que TimescaleDB hiciera *chunking* exitoso y convirtiéndola en un motor legítimo de series de tiempo.

### 3. Kafka Sin Disponibilidad — Graceful Degradation vs. Fail-Fast
- **Sugerencia de IA:** Ante una caída de Kafka, la IA generó un `throw new InternalServerErrorException()` directo, dejando el endpoint de ingesta completamente inoperativo.
- **El Problema:** En un sistema de flota, perder la ingesta porque el broker Kafka está calentando (o el contenedor tarda en arrancar) es inaceptable. Ningún conductor podría reportar telemetría.
- **Mi refactorización:** Envolví el `publishTelemetry` en un bloque `try/catch`. Si Kafka falla, el payload se procesa **sincrónicamente** a través del Circuit Breaker directamente hacia la base de datos. El conductor nunca recibe un error, y el sistema degrada elegantemente hasta que Kafka se recupera. Esta es la diferencia entre un sistema que "funciona" y uno que es **resiliente**.

---

## 📊 Resultados de Prueba de Carga (k6)

```
checks_succeeded...: 100.00%  1960 out of 1960
✓ status is 202
✓ status is 400 (Bad Request)

http_req_duration..: avg=13.9ms  min=1.06ms  med=8.69ms  max=228.08ms
http_req_failed....: 3.94%  (errores inyectados intencionalmente — caos)
http_reqs..........: 2181   (~17.6 req/s)
vus_max............: 100 vehículos concurrentes
```

---

## 🏗️ Estructura del Proyecto

```
project/                        # Monorepo orquestador (este repositorio)
├── backend/          [submódulo]  # NestJS — Kafka Consumer, Telemetry API, AI Agent
├── frontend/         [submódulo]  # Next.js — Dashboard reactivo con WebSockets
├── mobile/           [submódulo]  # React Native / Expo — App del conductor (Offline-First)
├── .gitmodules       # Definición de submódulos
├── docker-compose.yml
├── main.tf           # Terraform IaC (AWS MSK + RDS + ECS Fargate)
├── load-test.js      # k6 — Prueba de caos y carga
└── .github/
    └── workflows/
        └── mobile-cd.yml  # CI/CD Móvil (GitHub Actions)
```

---

## 🔗 Tech Stack

| Capa | Tecnología |
|------|-----------|
| Frontend Web | Next.js 14, React, TypeScript, Tailwind CSS |
| Mobile | React Native, Expo, AsyncStorage (Offline-First) |
| Backend | NestJS, TypeScript |
| Mensajería | Apache Kafka (KRaft mode) |
| Persistencia | TimescaleDB (PostgreSQL 15) + Prisma ORM |
| Resiliencia | Opossum (Circuit Breaker) |
| IA | Intent Parser + OpenAI GPT-4o-mini (fallback) |
| Infraestructura | Docker Compose (local), Terraform (AWS) |
| Testing | k6 (load & chaos testing) |
| CI/CD | GitHub Actions (mobile deployment) |
