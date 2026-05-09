//! CRUD sobre la tabla `analyses`.

use std::os::raw::c_char;

use crate::{
    error::{clear_last_error, set_last_error},
    handle::{handle_ref, DbHandle},
    util::{cstr_to_str, json_to_cstring},
};

// ─── INSERT ───────────────────────────────────────────────────────────────────

/// Inserta un análisis.
///
/// Parámetros:
/// - `batch_id`: ID del batch analizado
/// - `timestamp`: ISO-8601 UTC
/// - `risk`: "BAJO" | "MEDIO" | "ALTO"
/// - `analysis`: texto libre del LLM
/// - `elapsed_s`: segundos que tardó el LLM (f64 como string "1.23")
/// - `suspicious_count`: dominios sospechosos
/// - `packets`: total de paquetes
/// - `bytes_fmt`: texto formateado "1.2 MB"
///
/// Devuelve el rowid del análisis (≥1), o 0 en error.
///
/// # Safety
/// Todos los punteros deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn analysis_insert(
    handle:          *mut DbHandle,
    batch_id:        i64,
    timestamp:       *const c_char,
    risk:            *const c_char,
    analysis:        *const c_char,
    elapsed_s:       f64,
    suspicious_count: i64,
    packets:         i64,
    bytes_fmt:       *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let ts   = match cstr_to_str(timestamp) { Some(s) => s, None => { set_last_error("timestamp nulo"); return 0; } };
    let risk = cstr_to_str(risk).unwrap_or("BAJO");
    let txt  = cstr_to_str(analysis).unwrap_or_default();
    let bfmt = cstr_to_str(bytes_fmt).unwrap_or("0 B");

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO analyses \
         (batch_id, timestamp, risk, analysis, elapsed_s, suspicious_count, packets, bytes_fmt) \
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
        rusqlite::params![batch_id, ts, risk, txt, elapsed_s, suspicious_count, packets, bfmt],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

// ─── SELECT ───────────────────────────────────────────────────────────────────

/// Devuelve los `limit` análisis más recientes como JSON array.
///
/// JSON por elemento:
/// ```json
/// {"id":1,"batch_id":1,"timestamp":"...","risk":"ALTO","analysis":"...","elapsed_s":1.2,
///  "suspicious_count":2,"packets":100,"bytes_fmt":"10 KB"}
/// ```
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn analysis_list_recent(handle: *mut DbHandle, limit: i64) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let lim = if limit <= 0 { 20 } else { limit };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT id, batch_id, timestamp, risk, analysis, elapsed_s, \
                suspicious_count, packets, bytes_fmt \
         FROM analyses ORDER BY id DESC LIMIT ?1"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map(rusqlite::params![lim], |row| {
        Ok(serde_json::json!({
            "id":              row.get::<_, i64>(0)?,
            "batch_id":        row.get::<_, i64>(1)?,
            "timestamp":       row.get::<_, String>(2)?,
            "risk":            row.get::<_, String>(3)?,
            "analysis":        row.get::<_, String>(4)?,
            "elapsed_s":       row.get::<_, f64>(5)?,
            "suspicious_count":row.get::<_, i64>(6)?,
            "packets":         row.get::<_, i64>(7)?,
            "bytes_fmt":       row.get::<_, String>(8)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(vec) => json_to_cstring(&serde_json::Value::Array(vec)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Devuelve el análisis del batch `batch_id` como JSON, o NULL si no existe.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn analysis_get_by_batch(
    handle:   *mut DbHandle,
    batch_id: i64,
) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    let res = conn.query_row(
        "SELECT id, batch_id, timestamp, risk, analysis, elapsed_s, \
                suspicious_count, packets, bytes_fmt \
         FROM analyses WHERE batch_id=?1 ORDER BY id DESC LIMIT 1",
        rusqlite::params![batch_id],
        |row| {
            Ok(serde_json::json!({
                "id":              row.get::<_, i64>(0)?,
                "batch_id":        row.get::<_, i64>(1)?,
                "timestamp":       row.get::<_, String>(2)?,
                "risk":            row.get::<_, String>(3)?,
                "analysis":        row.get::<_, String>(4)?,
                "elapsed_s":       row.get::<_, f64>(5)?,
                "suspicious_count":row.get::<_, i64>(6)?,
                "packets":         row.get::<_, i64>(7)?,
                "bytes_fmt":       row.get::<_, String>(8)?,
            }))
        },
    );

    match res {
        Ok(v) => json_to_cstring(&v),
        Err(rusqlite::Error::QueryReturnedNoRows) => std::ptr::null_mut(),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Cuenta el total de análisis. Devuelve -1 en error.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn analysis_count(handle: *mut DbHandle) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return -1; }
    };
    let conn = h.conn.lock();
    match conn.query_row("SELECT COUNT(*) FROM analyses", [], |r| r.get::<_, i64>(0)) {
        Ok(n) => n,
        Err(e) => { set_last_error(e.to_string()); -1 }
    }
}

/// Cuenta análisis por nivel de riesgo.
/// Devuelve JSON: `{"BAJO":10,"MEDIO":3,"ALTO":1}` o NULL en error.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn analysis_count_by_risk(handle: *mut DbHandle) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT risk, COUNT(*) FROM analyses GROUP BY risk"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let mut map = serde_json::Map::new();
    let it = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    });
    match it {
        Ok(rows) => {
            for r in rows.flatten() {
                map.insert(r.0, serde_json::Value::Number(r.1.into()));
            }
            json_to_cstring(&serde_json::Value::Object(map))
        }
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}
