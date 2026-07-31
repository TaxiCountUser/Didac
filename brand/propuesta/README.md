# Propuesta: monograma del titular en la parrilla

Juego completo de marca con la **ligadura CT creada por el titular**, en las dos variantes
que quedaron vivas tras descartar los ámbares por falta de contraste.

- `negro/` — monograma en negro cálido `#1E1B16`, el mismo color de "TAXI" en el logotipo.
- `calado/` — monograma calado: es un hueco en la chapa y deja ver lo que haya detrás.
- `comparativa.png` — las dos, lado a lado, en todos los soportes.

**Esto todavía no es la marca oficial.** Lo que hay en `brand/` sigue siendo el monograma
"TC" geométrico. Cuando se elija variante, se promueve esta carpeta y se regeneran también
el asset de la app y el archivo de la OEPM.

Dos detalles comunes a las dos variantes, porque el color no los resuelve:

- En **blanco y negro** el monograma va siempre calado. Sobre carrocería negra un monograma
  negro sería invisible.
- En el **icono de app** la carrocería es crema sobre fondo ámbar, así que "calado" ahí
  significa que el monograma toma el ámbar del fondo.

Se regenera todo con:

```bash
node brand/generar-marca.js negro  brand/propuesta/negro
node brand/generar-marca.js calado brand/propuesta/calado
```

El generador lee el monograma de `brand/monograma-ct.svg`, así que si se retoca el dibujo
basta con volver a lanzarlo.
