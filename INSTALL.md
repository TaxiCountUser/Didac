# Guía de instalación del entorno — TaxiCount (Fase 0)

> En esta máquina **faltan** Docker, Node.js y Flutter. Sin ellos, el
> `DevEnvironmentBootLoop` (levantar contenedores, health checks, migraciones,
> smoke test) **no puede ejecutarse**. Sigue estos pasos para dejar el entorno
> listo y luego retomar el loop.

Detectado en el diagnóstico (`2026-06-19`):

| Herramienta            | Estado            |
| ---------------------- | ----------------- |
| git                    | ✅ instalado      |
| winget                 | ✅ disponible     |
| Docker / Docker Desktop| ❌ falta          |
| Node.js / npm          | ❌ falta          |
| Flutter                | ❌ falta          |
| WSL (distro Linux)     | ❌ solo el lanzador, sin distro |
| Virtualización (firmware) | ✅ habilitada  |

---

## 1. Node.js (no requiere admin)

```powershell
winget install --id OpenJS.NodeJS.LTS -e --source winget
```

Cierra y reabre la terminal y verifica:

```powershell
node --version   # >= 18
npm --version
```

> Node es lo único estrictamente necesario para correr el **smoke test** y los
> **tests del backend** fuera de Docker.

---

## 2. Docker Desktop (requiere admin + reinicio)

Docker Desktop **no puede instalarse de forma autónoma**: necesita permisos de
administrador, aceptar su licencia en la GUI, instalar el backend WSL2 y
reiniciar el sistema. Hazlo manualmente:

```powershell
# Ejecutar en una terminal ABIERTA COMO ADMINISTRADOR
winget install --id Docker.DockerDesktop -e --source winget
```

Después:

1. **Instala una distro WSL2** (Docker Desktop la necesita como backend):
   ```powershell
   wsl --install -d Ubuntu
   ```
   (Reinicia si lo pide.)
2. **Reinicia** Windows.
3. Abre **Docker Desktop**, acepta la licencia y espera a que el icono indique
   *"Engine running"*.
4. Verifica:
   ```powershell
   docker --version
   docker compose version
   docker run --rm hello-world
   ```

---

## 3. Flutter (opcional para la Fase 0; necesario para el frontend)

El smoke test E2E **no** depende de Flutter. Instálalo cuando trabajes la app:

```powershell
winget install --id Google.Flutter -e --source winget
# o sigue https://docs.flutter.dev/get-started/install/windows
flutter doctor
```

---

## 4. Retomar el DevEnvironmentBootLoop

Con Docker y Node listos, desde `C:\Users\Usuario\Documents\TaxiCount`:

```powershell
copy .env.example .env
docker compose up -d --build

# Esperar a que los servicios estén "healthy"
docker compose ps

# Instalar deps del smoke test y ejecutarlo
cd smoke-test
npm install
node test.js
cd ..
```

Resultado esperado del smoke test: `✅ SMOKE TEST OK — entorno dev validado.`

Para reiniciar limpio entre intentos:

```powershell
docker compose down -v
```

Cuando el smoke test pase, haz el commit de cierre de fase:

```powershell
git add -A
git commit -m "Fase 0 completada: entorno dev validado"
```
