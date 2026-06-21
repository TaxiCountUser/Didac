# Documentación operativa — TaxiCount

Guías para el equipo de operaciones y mantenimiento (Fase 6, production-ready).

| Documento | Contenido |
| --------- | --------- |
| [performance-report.md](performance-report.md) | Pruebas de carga k6, umbrales p95 y resultados. |
| [security-audit.md](security-audit.md) | Auditoría OWASP Top 10 y resolución de vulnerabilidades. |
| [production-setup.md](production-setup.md) | Despliegue en Supabase Cloud + DigitalOcean + Vercel, dominios y SSL. |
| [monitoring.md](monitoring.md) | Sentry, UptimeRobot y runbook de alertas. |
| [disaster-recovery.md](disaster-recovery.md) | RTO/RPO, backups y procedimientos de recuperación. |
| [cost-estimate.md](cost-estimate.md) | Estimación de coste mensual (< 150 €). |
| [e2e-staging-report.md](e2e-staging-report.md) | Suite E2E de staging y resultados. |

## Procedimiento de release

1. Fusionar cambios en `main` (CI verde: lint + tests backend y Flutter).
2. Crear y publicar un tag de versión: `git tag v1.0.0 && git push origin v1.0.0`.
3. El workflow [`deploy.yml`](../.github/workflows/deploy.yml) construye y
   despliega backend (GHCR + VPS) y web (Vercel) si los *secrets*/`vars` de
   despliegue están configurados.
4. Verificar `https://api.taxicount.app/health` y un smoke test funcional.
