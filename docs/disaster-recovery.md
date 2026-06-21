# Plan de recuperación ante desastres — TaxiCount (Fase 6)

## Objetivos

| Métrica | Valor | Justificación |
| ------- | ----- | ------------- |
| **RTO** (Recovery Time Objective) | **2 horas** | Tiempo máximo para volver a estar operativos. |
| **RPO** (Recovery Point Objective) | **24 horas** | Pérdida máxima de datos aceptable (backups diarios). |

## Backups

- **Supabase Pro** realiza **backups diarios automáticos** con **7 días de
  retención** (Database → Backups). No requiere configuración adicional.
- **Point-in-Time Recovery (PITR)**: disponible como add-on de Supabase si se
  necesita un RPO menor a 24 h (recomendado tras crecer la base de usuarios).
- **Backup lógico bajo demanda / verificación**: el script
  [`scripts/restore-backup.sh`](../scripts/restore-backup.sh) descarga un dump
  del esquema `public` y lo restaura en un entorno **local** (nunca producción),
  útil para probar la integridad del backup y para entornos de staging.

## Escenarios y procedimientos

### A) Corrupción / pérdida de datos en la BD
1. Identificar el momento del incidente y el último backup válido.
2. En el panel de Supabase → Database → Backups, **restaurar** el backup diario
   (o usar PITR si está activo) a un punto anterior al incidente.
3. Verificar integridad con conteos y un smoke test funcional.
4. Comunicar a los usuarios la posible pérdida de datos del último intervalo
   (≤ 24 h).
- **RTO estimado**: 30–60 min. **RPO**: ≤ 24 h.

### B) Caída del backend (VPS / DO App Platform)
1. Revisar logs y health (`/health`) y el dashboard de DO.
2. Reiniciar la App. Si persiste, **rollback** a la imagen del release anterior:
   ```bash
   docker pull ghcr.io/<owner>/taxicount/backend:<tag-anterior>
   docker stop taxicount-backend && docker rm taxicount-backend
   docker run -d --name taxicount-backend --restart unless-stopped \
     -p 3000:3000 --env-file /opt/taxicount/backend.env \
     ghcr.io/<owner>/taxicount/backend:<tag-anterior>
   ```
3. La BD (Supabase) es independiente del backend: no se ve afectada.
- **RTO estimado**: 15–30 min. **RPO**: 0 (sin pérdida de datos).

### C) Pérdida total del proveedor de cómputo (VPS)
1. Aprovisionar un nuevo VPS / App siguiendo
   [production-setup.md](production-setup.md).
2. Configurar variables de entorno y desplegar la última imagen `:latest` o el
   tag estable.
3. Actualizar DNS de `api.taxicount.app` al nuevo host.
- **RTO estimado**: 1–2 h (incluye propagación DNS). **RPO**: 0.

### D) Restaurar a un entorno de staging/local para pruebas
```bash
SOURCE_DB_URL="postgresql://postgres:PASS@db.<ref>.supabase.co:5432/postgres" \
  ./scripts/restore-backup.sh
# Destino por defecto: Postgres local de docker-compose (con salvaguarda
# para no escribir nunca en un host de Supabase).
```

## Pruebas del plan
- **Trimestral**: ejecutar `restore-backup.sh` contra staging y validar conteos
  + smoke test. Registrar fecha y resultado.
- **Tras cada cambio de esquema**: confirmar que las migraciones se aplican
  limpiamente sobre una copia restaurada.

## Contactos y escalado
- Responsable de guardia: definir en el runbook del equipo.
- Estados de proveedores: status.supabase.com, status.digitalocean.com,
  status.stripe.com.
