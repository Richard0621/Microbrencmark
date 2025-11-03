# 🔧 Solución: Métricas en Cero

## ❌ Problema Identificado

En el CSV generado (`results_cpp.csv`), varias métricas aparecen en **cero**:

```csv
instructions = 0
cycles = 0
ipc = 0
cache_misses = 0
branch_misses = 0
energy_uj = 0
energy_J = 0
```

---

## 🔍 Causas del Problema

### 1️⃣ **Métricas de perf no se integran**

**Problema**: El script `run_benchmark_with_perf.sh` ejecuta `perf stat` y muestra las métricas en consola, pero **NO las escribe en el CSV**.

**Por qué**: El programa C++ no tiene acceso directo a los contadores de perf, solo muestra los valores en consola después de ejecutar.

**Código problemático** (benchmark_monitor.cpp):
```cpp
// Perf metrics (se llenarán desde el wrapper de perf)
// Por ahora, valores por defecto
result.perf.instructions = 0;  // ← SIEMPRE CERO!
result.perf.cycles = 0;
result.perf.ipc = 0.0;
result.perf.cache_misses = 0;
result.perf.branch_misses = 0;
```

### 2️⃣ **RAPL requiere permisos de root**

**Problema**: Para leer energía de RAPL se necesita `sudo`.

**Archivo**: `/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj`

```bash
# Sin sudo:
cat /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj
# Permission denied

# Con sudo:
sudo cat /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj
# 123456789  ← Valor correcto
```

---

## ✅ Soluciones Implementadas

### **Solución 1: Script mejorado que actualiza el CSV**

He modificado `run_benchmark_with_perf.sh` para que:

1. ✅ Ejecute perf stat y capture las métricas
2. ✅ Parsee los valores de `instructions`, `cycles`, `cache_misses`, `branch_misses`
3. ✅ Calcule IPC = instructions / cycles
4. ✅ **Actualice el CSV** reemplazando los ceros con valores reales

**Flujo actualizado**:
```
benchmark_monitor (genera CSV con perf=0)
    ↓
perf stat (captura métricas)
    ↓
Script parsea perf_output.tmp
    ↓
Script actualiza CSV con valores reales
    ↓
CSV final con métricas completas ✅
```

### **Solución 2: Script de verificación**

He creado `check_metrics_availability.sh` que verifica:

- ✅ CPUFreq (frecuencia, governor)
- ✅ RAPL (energía)
- ✅ Temperatura (thermal zones / hwmon)
- ✅ perf (disponibilidad y permisos)
- ✅ Número de CPUs

**Uso**:
```bash
# Sin sudo (info básica)
./check_metrics_availability.sh

# Con sudo (valores completos)
sudo ./check_metrics_availability.sh
```

---

## 🚀 Cómo Usar Ahora

### 1️⃣ Verificar disponibilidad de métricas

```bash
cd benchmark_monitor_C
sudo ./check_metrics_availability.sh
```

Esto te mostrará qué métricas están disponibles en tu sistema.

### 2️⃣ Ejecutar benchmark con **sudo**

```bash
sudo ./run_benchmark_with_perf.sh
```

**Importante**: Usar `sudo` es crítico para:
- ✅ Leer energía de RAPL
- ✅ Acceder a contadores hardware de perf
- ✅ Obtener todas las métricas

### 3️⃣ Verificar el CSV

```bash
cat results_cpp.csv
```

Ahora deberías ver:
```csv
timestamp,benchmark,N,cpu_freq_MHz,...,instructions,cycles,ipc,...,energy_uj,...
2025-10-24T...,BM_VectorAdd/16384,16384,2400,...,12345678,5432109,2.273,...,123456,...
```

✅ **Ya NO ceros!**

---

## 📊 Comparación: Antes vs Después

### ❌ Antes (con ceros)
```csv
instructions,cycles,ipc,cache_misses,branch_misses,energy_uj
0,0,0,0,0,0
```

### ✅ Después (con valores reales)
```csv
instructions,cycles,ipc,cache_misses,branch_misses,energy_uj
12345678,5432109,2.273,123456,45678,987654
```

---

## 🔧 Troubleshooting

### Si instructions y cycles siguen en cero:

**Causa**: perf no tiene permisos suficientes.

**Solución**:
```bash
# Ver nivel de paranoid
cat /proc/sys/kernel/perf_event_paranoid

# Si es > 1, reducir (temporal):
sudo sysctl -w kernel.perf_event_paranoid=1

# Permanente (añadir a /etc/sysctl.conf):
kernel.perf_event_paranoid = 1
```

### Si energy_uj sigue en cero:

**Posibles causas**:
1. No estás usando `sudo`
2. CPU no es Intel (RAPL es solo Intel)
3. Sistema virtualizado (RAPL no disponible en VMs)

**Verificar**:
```bash
# Ver si RAPL está disponible
ls /sys/class/powercap/intel-rapl/

# Intentar leer con sudo
sudo cat /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj
```

### Si temperature_C sigue en cero:

**Verificar sensores**:
```bash
# Thermal zones
cat /sys/class/thermal/thermal_zone0/temp

# HWMon
cat /sys/class/hwmon/hwmon0/temp1_input

# O instalar sensors
sudo apt-get install lm-sensors
sensors
```

---

## 📝 Archivos Modificados

1. ✅ `run_benchmark_with_perf.sh` - Ahora actualiza el CSV con métricas de perf
2. ✅ `check_metrics_availability.sh` - Nuevo script de verificación

---

## 🎯 Resumen

**Problema**: Métricas en cero en el CSV

**Causa principal**: 
- Perf metrics no se integraban al CSV
- Falta de permisos (sudo)

**Solución**:
- ✅ Script mejorado que actualiza CSV con valores de perf
- ✅ Script de verificación de disponibilidad
- ✅ Ejecutar con `sudo`

**Comando correcto**:
```bash
sudo ./run_benchmark_with_perf.sh
```

---

## ✅ Verificación Final

Después de ejecutar, verifica que NO haya ceros:

```bash
# Ver CSV
cat results_cpp.csv | column -t -s','

# Verificar que instructions > 0
awk -F',' 'NR>1 {print "Instructions:", $8}' results_cpp.csv

# Verificar que energy_uj > 0
awk -F',' 'NR>1 {print "Energy:", $13}' results_cpp.csv
```

Si sigues viendo ceros, ejecuta:
```bash
sudo ./check_metrics_availability.sh
```

Y compárteme la salida para diagnosticar el problema específico de tu sistema.
