# TurismoUQ — Proyecto integrador Bases de Datos II (grupo 01N)

Valery Andrea Ortiz Mesa · Jhonatan David Vivas Arango
Docente: Carolina Londoño Idárraga — Universidad del Quindío

Base de datos Oracle de una plataforma de reservas de alojamiento para los 12 municipios del Quindío.

## Orden de ejecución

Ejecutar cada script completo (F5 en SQL Developer, o `@archivo.sql` en SQL*Plus), en este orden, con el mismo usuario:

| # | Script | Entrega | Qué hace |
|---|--------|---------|----------|
| 01 | `scripts/01_ddl.sql` | 1 (corregida) | Borra lo que exista y crea las 16 tablas con PK, FK, CHECK, NOT NULL y UNIQUE |
| 02 | `scripts/02_datos.sql` | 1 (corregida) | Carga el volumen mínimo con PL/SQL y DBMS_RANDOM (2 a 5 min) |
| 03 | `scripts/03_consultas.sql` | 1 (corregida) | Las 7 consultas de análisis |
| 04 | `scripts/04_paquete_pkg_turismo.sql` | **2 – entregable 1** | Paquete `PKG_TURISMO`: `fn_valor_estadia`, `sp_crear_reserva`, cursor de liquidación mensual |
| 05 | `scripts/05_disparadores.sql` | **2 – entregable 2** | Disparador de sentencia (auditoría de TARIFA) y de fila (solapes) |
| 06 | `scripts/06_tablespace_vista_materializada.sql` | **2 – entregable 3** | Tablespace del histórico y vista materializada de ocupación mensual |
| 07 | `scripts/07_pruebas_entrega2.sql` | **2 – entregable 4** | Pruebas de cada componente; genera `07_resultado_pruebas.txt` |

La evidencia de la ejecución está en `evidencias/`.

Privilegios necesarios: CREATE TABLE, VIEW, SEQUENCE, PROCEDURE, TRIGGER, MATERIALIZED VIEW, JOB y TABLESPACE (por ejemplo, el usuario SYSTEM).

## Correcciones de la Entrega 1

| Observación de la docente | Corrección | Dónde |
|---|---|---|
| Al DDL le falta el UNIQUE en el correo del cliente | `CONSTRAINT uq_cliente_correo UNIQUE (correo)` | 01 |
| RESERVA_SERVICIO tiene 7.520 filas frente a 40.000 | Cada alojamiento ofrece de 0 a 8 servicios según su tipo (antes, uno solo en 30 alojamientos). Ahora hay más de 40.000 líneas | 02 §6 y §8 |
| Las temporadas no cubren 2024 y dejan 371 días de 2025–2026 sin temporada | 10 temporadas por año para 2024–2027 que cubren todos los días, sin cruces. El script lo verifica: 0 días sin temporada y 0 días con cruce | 02 §2 |
| La C2 descarta el 64 % de los ingresos | Con la cobertura completa ningún pago queda por fuera. La prueba P0.6 muestra que el total de C2 es igual al total de pagos exitosos | 02, 03, 07 |
| La C2 agrupa la temporada sin su año | `ROLLUP (mu.nombre, ta.nombre, (t.anio, t.nombre))`, con columna compuesta | 03 |
| Los montos de pago deben salir de TARIFA | Monto = estadía noche por noche contra TARIFA + servicios (precio × cantidad). La prueba P0.5 compara los pagos con `fn_valor_reserva`: 0 diferencias | 02 §8, 07 |
| Quedan 2.100 solapes de habitación | El generador revisa día por día que la habitación esté libre antes de asignarla. Resultado: 0 solapes | 02 §8 |
| C5: declarar VARIABLE y EXEC (falla con SP2-0552) | `VARIABLE` y `EXEC` quedan escritos en el script antes de la consulta | 03 |
| C6: UNPIVOT sobre columnas reales | UNPIVOT de `fecha_reserva`, `fecha_checkin` y `fecha_checkout` de RESERVA (actividad operativa por mes) | 03 |

Cambios adicionales al modelo: `RESERVA_HABITACION.num_huespedes` (lo usa la validación de capacidad), `UNIQUE (alojamiento_id, nombre)` en SERVICIO, un CHECK para que las fechas de cada temporada estén dentro de su año y `COMMENT ON TABLE` en todas las tablas.

## Entrega 2 — Capa PL/SQL

### Paquete `PKG_TURISMO` (script 04)

- **`fn_valor_estadia(id_habitacion, fecha_in, fecha_out)`**: recorre la estadía noche por noche, desde el check-in hasta la víspera del check-out, y cobra cada noche con la tarifa de la temporada que la contiene. Guarda la temporada vigente en variables y solo vuelve a consultar cuando la noche cruza a otra temporada. Errores: -20002 (fechas), -20005 (habitación), -20006 (noche sin tarifa), -20007 (temporadas cruzadas).
- **`sp_crear_reserva`**: valida las fechas (-20002), los huéspedes, la existencia del cliente (-20004) y de la habitación (-20005), la capacidad (-20003) y la disponibilidad (-20001). Bloquea la fila de la habitación con `FOR UPDATE` para que dos sesiones no reserven la misma habitación a la vez. Calcula el valor antes de insertar. No hace COMMIT: la transacción la confirma quien llama.
- **`sp_agregar_habitacion`**: para reservas de grupo. Exige que la habitación sea del mismo alojamiento (-20010) y que sus fechas queden dentro del rango de la reserva.
- **`sp_liquidacion_mensual(anio, mes, alojamiento, comision)`**: proceso masivo con el **cursor explícito parametrizado** `c_liquidacion(cp_inicio, cp_fin, cp_alojamiento)`, recorrido con OPEN/FETCH/CLOSE. Por alojamiento calcula las noches vendidas dentro del mes (una estadía que cruza de mes se reparte), el valor del hospedaje con `fn_valor_estadia` sobre el tramo del mes y los servicios. Luego aplica la comisión y el neto, guarda el resultado en `LIQUIDACION_MENSUAL` e imprime el reporte.
- Las excepciones propias se declaran en la especificación con `PRAGMA EXCEPTION_INIT`, de modo que quien llame puede atraparlas por nombre (`pkg_turismo.e_capacidad_excedida`).

### Disparadores (script 05)

- **`trg_tarifa_auditoria`** (sentencia): un disparador de sentencia puro no tiene acceso a `:OLD`/`:NEW`. Por eso es un *compound trigger*: `BEFORE STATEMENT` toma quién (usuario BD, usuario SO, equipo, programa) y cuándo, `AFTER EACH ROW` solo acumula el valor anterior y el nuevo, y `AFTER STATEMENT` escribe toda la auditoría en `AUDITORIA_TARIFA` con un solo `FORALL`. Todas las filas de una misma sentencia comparten `id_sentencia`.
- **`trg_reshab_no_solape`** (fila, `BEFORE INSERT ... FOR EACH ROW`): rechaza con -20011 una línea que se cruce con otra línea activa de la misma habitación, aunque se inserte directamente en la tabla sin pasar por el paquete. El día de check-out queda libre. No permite cambiar por UPDATE las fechas ni la habitación de una línea (-20013); así se evita el error de tabla mutante y nadie puede saltarse la regla.

### Tablespace `TS_TURISMO_HISTORICO` (script 06)

Contiene `RESERVA_HISTORICO` y su índice, que se llenan con `sp_archivar_reservas`. Se separa del tablespace operativo por cinco razones:

1. El patrón de acceso es distinto: RESERVA es OLTP y el histórico solo crece por cargas periódicas.
2. El crecimiento queda controlado con su propio datafile y `MAXSIZE`, así que el histórico no puede llenar el espacio de las reservas nuevas.
3. Respaldo: puede ponerse en READ ONLY después de cada cierre, respaldarse una sola vez y no retrasar la restauración del tablespace operativo.
4. Su datafile puede vivir en un disco más barato.
5. Admite ajustes propios, como `PCTFREE 0`, porque sus filas no se actualizan.

### Vista materializada `MV_OCUPACION_MENSUAL` (script 06)

Tiene una fila por alojamiento y mes con noches disponibles, noches vendidas (reservas CONFIRMADA o COMPLETADA, repartidas por mes con la tabla `CALENDARIO`) y porcentaje de ocupación. Incluye los meses sin ventas.

**Política de refresco: COMPLETE ON DEMAND, programada todos los días a las 2:00 a.m. con DBMS_SCHEDULER, más un refresco manual en cada cierre de mes.**

- No es FAST porque la consulta usa CROSS JOIN, LEFT JOIN contra subconsultas agregadas y un join por rango de fechas, construcciones que Oracle no refresca de forma incremental. Además, los logs de vista materializada encarecerían cada reserva.
- No es ON COMMIT porque metería un recálculo pesado dentro de cada transacción de reserva.
- Es diaria porque la ocupación mensual es un indicador de gerencia y un día de retraso es aceptable. La vista es pequeña (unas 2.200 filas) y a las 2:00 a.m. no compite con las reservas.
- Usa `atomic_refresh => TRUE`, así quien consulte durante el refresco nunca ve la vista vacía.

## Supuestos

- Una habitación está ocupada por toda reserva que no esté CANCELADA. El día de check-out queda libre.
- La comisión de la plataforma en la liquidación es del 10 % por defecto (es un parámetro).
- Los datos se generan con la semilla fija `DBMS_RANDOM.SEED(20261022)`. El estado de las reservas futuras depende de la fecha en que se ejecuta el script 02.
